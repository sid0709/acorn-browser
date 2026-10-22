//! The one place between the model's reply and the browser where the harness may stop, change,
//! or question the plan. It may change the reply's status and message, take actions out of the
//! plan, and say why in `dropped`. The rules, in the order they run:
//!
//! - "Done" is the page's confirmation, not the model's word. A model can say done without that
//!   being so: a recorded run stopped with the form still open and nothing submitted, because it
//!   had decided the task did not apply, and the run was shown to the person as finished. So the
//!   decision model is asked whether the screen shows the task done; when it does not, the model
//!   is sent back to finish or to say plainly why it did not, and a run that still ends "done"
//!   without the page's confirmation is reported as one that could not confirm, never as done.
//! - The person is asked last. A model that stops for them (a CAPTCHA, a code, a document) has
//!   often done so with fillable fields still empty: the optional ones the person's details
//!   answer, a part of the page it never scrolled to, or the rest of the step it stopped on. So a
//!   stop is not accepted at once: a reason the task's own policy does not allow is sent back;
//!   when the model read fields as empty on its last survey, the decision model is asked which of
//!   them only the person can fill, and the stop is sent back with the rest named, as many times
//!   as a pass fills some of them; a stop for a human check the screen does not show is sent back
//!   once, to press the button that sends the page first; otherwise the first stop of a run is
//!   sent back once, to go through the whole page, and later ones while parts of it are unseen.
//! - An action that cannot be taken back goes out only as the person allows. The model names
//!   what each click commits (`Action::commit`); the task's allowances say, per kind, whether
//!   the run may do it on its own, must ask first, or never may. A click to ask about is held
//!   with what follows it, a question goes to the person, and the rest of the plan goes on; the
//!   answer sets the allowance and tells the model. A click the person reserved for themselves
//!   is held, and when nothing else is left the run ends ready for them.
//! - The fixed rules, whatever the person allows. A click that sends the page or goes on is
//!   held when part of the plan could not be carried out: a recorded run pressed Submit with a
//!   required field it had not filled, which turned every unanswered question red. It is held
//!   while the to-do list still has a required field empty on the page, even one the same plan
//!   fills, a few times per page: the click goes out on a later look, once a survey shows the
//!   list clear. And when the page refused the click that sent it (the form is still there, with
//!   messages that answers are missing or wrong), the next such click is held for one look, so
//!   what the page asked for is set first.

use std::collections::BTreeMap;
use std::time::SystemTime;

use crate::action::{Action, Kind};
use crate::model::Reply;
use crate::observe::{Observation, without_fragment};
use crate::ports::{Decision, Part, Question};
use crate::prompt;
use crate::run::{Agent, Question as Asked, Status, StopInfo};
use crate::session::Session;
use crate::task::{Allowance, StopReason, Task};
use crate::trace::ModelCall;

/// What the person sees while the harness makes the model look again.
pub const DONE_PASS_MESSAGE: &str = "The page has not confirmed the task is done; looking again.";
/// What the person sees while the harness finishes before asking them.
pub const STOP_PASS_MESSAGE: &str = "Finishing everything else on the page before asking you.";
/// How long the model waits before it looks again, as the page may still be moving.
pub const PASS_WAIT_MS: u64 = 300;
/// The key of the question whether the screen shows the task done.
const ASK_DONE: &str = "done";
/// The key of the question whether the screen shows a check the person must pass.
const ASK_HUMAN_CHECK: &str = "human_check";
/// The start of the key of the question about a numbered empty field: `f1`, `f2`, ...
const ASK_PERSON_FIELD_PREFIX: &str = "f";
/// The key of the question whether the page refused the click that sent it.
const ASK_SEND_REFUSED: &str = "send_refused";
/// How many times on one page the click that sends it or goes on is held for fields the to-do
/// list still has empty: a field the model cannot fill does not keep the page from being sent
/// for ever.
pub const MAX_LIST_HOLDS: u32 = 3;

/// The click that sends the page or goes on, as the plan kept it: the page it was on, whether
/// it went through, and whether it commits something beyond the page.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CommitState {
    pub id: String,
    pub url: String,
    pub done: bool,
    pub send: bool,
}

/// How many times the click that sends the page was held on one page for the to-do list.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ListHold {
    pub url: String,
    pub count: u32,
}

/// A stop sent back for the fields the model read as empty: the page it was on and the fields
/// that were left to fill, so a pass that filled none of them is not sent back again.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FieldHold {
    pub url: String,
    pub left: Vec<String>,
}

impl Agent {
    /// Applies the rules to the model's reply before its plan goes out. `number` names the step,
    /// for an action the gate puts in.
    pub(crate) fn gate(&self, s: &mut Session, obs: &Observation, reply: &mut Reply, planned: &mut Vec<Action>, dropped: &mut Vec<String>, number: u32, lost: usize) {
        if reply.status == Status::Working {
            hold_commits_lost(s, planned, dropped, lost);
            hold_for_list(s, obs, planned, dropped);
        }
        let held = if reply.status == Status::Working { self.hold_irreversible(s, planned, dropped) } else { None };
        if reply.status == Status::Working {
            hold_refused_send(s, planned, dropped);
        }
        // The click the person reserved for themselves was all that was left: the run ends
        // ready for them, and no confirmation of "done" is asked of the screen.
        if let Some(kind) = s.held_reserved
            && (reply.status == Status::Done || (held == Some(Allowance::Never) && planned.is_empty()))
        {
            reply.status = Status::NeedPerson;
            reply.message = format!("Ready: everything else is done, and the click to {} was left for you.", kind.verb());
            reply.stop = Some(StopInfo {
                reason: StopReason::Reserved,
                problem: format!("Under your settings the run does not {} on its own.", kind.verb()),
                action: "Do that on the page yourself.".to_string(),
            });
            planned.clear();
        }
        if let Some(note) = self.hold_done(s, obs, reply) {
            reply.status = Status::Working;
            reply.message = DONE_PASS_MESSAGE.to_string();
            *planned = vec![Action::new(format!("s{number}a1"), Kind::Wait { ms: PASS_WAIT_MS })];
            s.notes.push(note);
        }
        if let Some(note) = self.hold_stop(s, obs, reply) {
            reply.status = Status::Working;
            reply.message = STOP_PASS_MESSAGE.to_string();
            *planned = vec![Action::new(format!("s{number}a1"), Kind::Wait { ms: PASS_WAIT_MS })];
            s.notes.push(note);
        }
    }

    /// Holds the first click that commits something beyond the page, and what follows it, when
    /// the person's settings say to ask first or never: the rest of the plan goes out, and the
    /// model is told. Says which allowance held it.
    fn hold_irreversible(&self, s: &mut Session, planned: &mut Vec<Action>, dropped: &mut Vec<String>) -> Option<Allowance> {
        let at = planned.iter().position(|a| a.commit.irreversible().is_some_and(|kind| s.task.allowance(kind) != Allowance::Auto))?;
        let kind = planned[at].commit.irreversible()?;
        let allowance = s.task.allowance(kind);
        let held = planned.split_off(at);
        let label = held[0].label.trim();
        let what = if label.is_empty() { format!("the click that would {}", kind.verb()) } else { format!("{label:?}") };
        let with = prompt::count(held.len() - 1, "later action");
        match allowance {
            Allowance::Ask => {
                dropped.push(format!("{what} was held back ({with} with it): the person is asked first whether the run may {}", kind.verb()));
                if s.asked_for.insert(kind) {
                    let question = Asked {
                        id: format!("q{}", s.questions.len() + 1),
                        text: format!("May the run {} on your behalf ({what})? Answer yes or no.", kind.verb()),
                        answer: None,
                        allows: Some(kind),
                    };
                    s.questions.push(question.clone());
                    s.asked_now.push(question);
                }
                s.notes.push(format!(
                    "The harness did not press {what}: the person is asked first whether you may {}. Go on with everything else meanwhile; when the page is complete and the person has allowed it (you will be told), plan that click again on its own.",
                    kind.verb()
                ));
            }
            _ => {
                dropped.push(format!("{what} was held back ({with} with it): the person does this themselves"));
                s.notes.push(format!(
                    "The harness did not press {what}: the person will {} themselves, so never press it. Do everything else; when nothing is left, report done, and the run ends as ready for them.",
                    kind.verb()
                ));
                s.held_reserved = Some(kind);
            }
        }
        Some(allowance)
    }

    /// Says whether the page refused the click that sent it: the click went through, the look
    /// after it is on the same address, and the decision model reads on the screenshots that the
    /// form is still there with messages that answers are missing or wrong, not a confirmation
    /// or the next step. The model is told, with the fields it read as empty, and the next such
    /// click is held for one look. A recorded run sent a page again at once, twice in two
    /// minutes, and the page refused it as possible spam. The session is locked.
    pub(crate) fn note_refused_send(&self, s: &mut Session, obs: &Observation) {
        if !s.commit.done || s.commit.url != without_fragment(&obs.url) || !self.checks_on(s) {
            return;
        }
        // This send is judged once: the next plan's send is a new one.
        s.commit = CommitState::default();
        let Some(decider) = self.decider.as_ref() else { return };
        let mut questions = BTreeMap::new();
        questions.insert(
            ASK_SEND_REFUSED.to_string(),
            Question::yes_no("The button that sends this form was just pressed. Does the page still show the same form, with messages that some answers are missing or wrong (text beside fields, or a list of problems), rather than a confirmation, a new step of the form with other questions, or a page that asks for something else?"),
        );
        let started = SystemTime::now();
        let answered = decider.decide(Decision { state: page_state(obs), questions });
        s.pending_calls.push(ModelCall::decision("the page refused the send", answered.as_ref(), started));
        let Ok(verdicts) = answered else { return };
        s.usage.add(verdicts.usage);
        if verdicts.yes(ASK_SEND_REFUSED).unwrap_or(0.0) < crate::review::LIKELY {
            return;
        }
        let left: Vec<String> = s.empty_fields_on(&obs.url).iter().map(|n| n.to_string()).collect();
        let named = if left.is_empty() {
            "Read on the survey which answers the page says are missing or wrong.".to_string()
        } else {
            format!("You read these fields as empty: {}. Read on the survey which answers the page says are missing or wrong.", quoted(&left))
        };
        s.send_refused = true;
        s.notes.push(format!(
            "The page did not accept the click that sends it: it still shows the form, with messages about its answers. {named} An answer that looks chosen on the screen may not be registered by the page. Set each such field again: for a choice, open its list and click the option you want; for a box, click it, clear it and enter the value again. A message beside a field that already shows the right answer may be left from the last send: do not change that field, it clears when the page is sent again. Plan only those fields on this look. The click that sends the page is held until your next look, when you have seen the fields set."
        ));
        s.survey_again = true;
    }

    /// Says whether a stop is sent back, with the note that tells the model why.
    fn hold_stop(&self, s: &mut Session, obs: &Observation, reply: &Reply) -> Option<String> {
        if !matches!(reply.status, Status::NeedPerson | Status::Stuck) {
            return None;
        }
        let reason = reply.stop.as_ref().map(|stop| stop.reason);
        // The harness's own stops stand.
        if reason.is_some_and(StopReason::is_harness_own) {
            return None;
        }
        let named = reason.map(prompt::reason_name).unwrap_or_else(|| "no reason given".to_string());
        let passes = self.config.stop_passes;
        // The task's own policy: a reason the person did not allow a stop for is sent back, as
        // long as the passes last; the step limit bounds a model that insists.
        if let Some(reason) = reason
            && !s.task.may_stop_for(reason)
            && s.stop_passes < passes
        {
            s.stop_passes += 1;
            return Some(format!(
                "You asked to stop ({named}), but under this task's rules that is not a reason to stop: the person wants the run to push on. Decide it yourself, choose what most people would choose, note it in \"assumed\", and keep going. Stop only for the reasons the rules list."
            ));
        }
        // A page the task cannot be done on has nothing for the run to finish: the stop stands.
        if reason == Some(StopReason::Unavailable) || s.nothing_left_to_fill(obs) {
            return None;
        }
        if let Some(note) = self.hold_for_fields(s, obs, reply, &named) {
            s.stop_passes += 1;
            return Some(note);
        }
        // A stop for a human check the screen does not show is sent back once, to press the
        // button that sends the page.
        if reason == Some(StopReason::Captcha)
            && s.captcha_passes == 0
            && self.config.captcha_confirm > 0.0
            && let Some(sure) = self.human_check_on_screen(s, obs)
            && sure < self.config.captcha_confirm
        {
            s.captcha_passes += 1;
            s.stop_passes += 1;
            return Some(format!(
                "You asked to stop for a human check (captcha), but a checker read the screen and is only {:.0}% sure there is one for the person to pass. A badge, logo or notice saying the page is protected is not a check: nothing on it needs their hand. Go on: press the button that sends the page (or goes on to the next step). Stop with need_person for the check only when the page then shows one to tick or solve, or will not go on until it is passed.",
                sure * 100.0
            ));
        }
        if passes == 0 || s.stop_passes >= passes {
            return None;
        }
        // The first stop always goes back once; later ones only while some of the page has not
        // been seen.
        if s.stop_passes > 0 && s.cover.gaps().is_empty() {
            return None;
        }
        s.stop_passes += 1;
        Some(format!(
            "You asked to stop for the person ({named}), but the person is asked last. Before anyone is asked, go through the whole page from its top: fill every field you can from the person's details, optional ones too wherever those details answer them, and do every other action that does not need the person. The note under the screenshot says which parts of the page you have not looked at; look at them. Say in your observation what you checked. Report need_person again only when nothing fillable is left."
        ))
    }

    /// Sends a stop back while the model read fields as empty on its last survey that the
    /// decision model judges the run's to fill rather than the person's, naming them; and not
    /// again once a pass filled none of them. Nothing is asked when no field was read as empty,
    /// or no decision model checks the run.
    fn hold_for_fields(&self, s: &mut Session, obs: &Observation, reply: &Reply, named: &str) -> Option<String> {
        let names: Vec<String> = s.empty_fields_on(&obs.url).iter().map(|n| n.to_string()).collect();
        if names.is_empty() || !self.checks_on(s) {
            return None;
        }
        let theirs = self.ask_person_fields(s, reply.stop.as_ref(), &names)?;
        let (own, left): (Vec<String>, Vec<String>) = names.into_iter().partition(|name| theirs.get(name).copied().unwrap_or(0.0) >= self.config.person_field);
        if left.is_empty() {
            return None;
        }
        let url = without_fragment(&obs.url).to_string();
        // The last pass filled none of them: the stop stands.
        if s.field_hold.url == url && left.len() >= s.field_hold.left.len() {
            return None;
        }
        s.field_hold = FieldHold { url, left: left.clone() };
        let after = if own.is_empty() { "what needs them".to_string() } else { quoted(&own) };
        Some(format!(
            "You asked to stop for the person ({named}), but you read these fields as still empty: {}. Fill each of them now from the person's details, with the answer most people give where the details say nothing, and do every other action that does not need the person, all in one plan; the person will do {after} after. Report need_person again only when nothing fillable is left.",
            quoted(&left)
        ))
    }

    /// Asks the decision model, for each field read as empty, whether only the person can fill
    /// it: the thing the model stops for, or of the same kind. Answers with the probability for
    /// each name; nothing when the checker could not answer.
    fn ask_person_fields(&self, s: &mut Session, stop: Option<&StopInfo>, names: &[String]) -> Option<BTreeMap<String, f64>> {
        let decider = self.decider.as_ref()?;
        let (problem, todo) = stop.map(|st| (st.problem.trim().to_string(), st.action.trim().to_string())).unwrap_or_default();
        let listed: Vec<String> = names.iter().enumerate().map(|(i, name)| format!("{} {name:?}", i + 1)).collect();
        let questions: BTreeMap<String, Question> = names
            .iter()
            .enumerate()
            .map(|(i, name)| {
                (
                    format!("{ASK_PERSON_FIELD_PREFIX}{}", i + 1),
                    Question::yes_no(format!(
                        "Can only the person fill field {}, {name:?}, by hand: is it what the helper stops for, or of the same kind (an identity or account number only they know, a code sent to them, a document only they have, a check that they are a person)? Answer no if the person's details, or the answer most people give, can fill it: a name, a demographic question, a yes or no about their situation, a number, a choice from a list.",
                        i + 1
                    )),
                )
            })
            .collect();
        let state = vec![Part::Text(format!(
            "A helper is doing a task on a web page for a person, and wants to stop and ask the person to act. The problem it reports: {} What it asks the person to do: {} These fields of the page are still empty: {}.",
            or_none(&problem),
            or_none(&todo),
            listed.join("; ")
        ))];
        let started = SystemTime::now();
        let answered = decider.decide(Decision { state, questions });
        s.pending_calls.push(ModelCall::decision(&format!("fields only the person can fill: {}", listed.join(", ")), answered.as_ref(), started));
        let verdicts = answered.ok()?;
        s.usage.add(verdicts.usage);
        Some(names.iter().enumerate().filter_map(|(i, name)| verdicts.yes(&format!("{ASK_PERSON_FIELD_PREFIX}{}", i + 1)).map(|p| (name.clone(), p))).collect())
    }

    /// Asks the decision model whether the screen shows a check the person must pass by hand,
    /// and how sure it is; nothing when it could not answer, so the model's word stands.
    fn human_check_on_screen(&self, s: &mut Session, obs: &Observation) -> Option<f64> {
        if !self.checks_on(s) {
            return None;
        }
        let decider = self.decider.as_ref()?;
        let mut questions = BTreeMap::new();
        questions.insert(
            ASK_HUMAN_CHECK.to_string(),
            Question::yes_no("Does this screen show a check that the person must pass by hand before the page goes on: a box to tick to prove they are a person, a picture or puzzle challenge, or a challenge dialog over the page? Answer no for a small badge, logo or notice, usually in a corner, saying the page is protected by such a service, and for a form that shows only its fields and the button that sends it."),
        );
        let started = SystemTime::now();
        let answered = decider.decide(Decision { state: page_state(obs), questions });
        s.pending_calls.push(ModelCall::decision("a check the person must pass by hand is on screen", answered.as_ref(), started));
        let verdicts = answered.ok()?;
        s.usage.add(verdicts.usage);
        verdicts.yes(ASK_HUMAN_CHECK)
    }

    /// Checks a "done" the model gave. Returns the note for the model when the run must not end
    /// yet (the model looks again); when the passes are used up, ends the run as stuck instead.
    fn hold_done(&self, s: &mut Session, obs: &Observation, reply: &mut Reply) -> Option<String> {
        if reply.status != Status::Done || self.config.done_passes < 0 || !self.checks_on(s) {
            return None;
        }
        let decider = self.decider.as_ref()?;
        let started = SystemTime::now();
        let answered = decider.decide(Decision { state: page_state(obs), questions: done_question(&s.task) });
        s.pending_calls.push(ModelCall::decision("the page shows the task done", answered.as_ref(), started));
        // A checker that cannot answer is not a reason to refuse the model's word.
        let verdicts = answered.ok()?;
        s.usage.add(verdicts.usage);
        let sure = verdicts.yes(ASK_DONE).unwrap_or(0.0);
        if sure >= self.config.done_confirm {
            return None;
        }
        if s.done_passes >= self.config.done_passes as u32 {
            // This stop is already the end: it is not sent back again.
            s.stop_passes = self.config.stop_passes;
            reply.status = Status::Stuck;
            reply.stop = Some(StopInfo {
                reason: StopReason::NotConfirmed,
                problem: "The page never showed that the task was done, so the run cannot call it done.".to_string(),
                action: "Look at the page: if something is still open, finish it yourself, then let the run go on.".to_string(),
            });
            reply.message = "The task was not confirmed as done.".to_string();
            return None;
        }
        s.done_passes += 1;
        Some(format!(
            "You reported done, but the screen does not show that the task is done (a checker read it, {:.0}% sure it did). Done means the page itself shows it: a confirmation, or the final state the task asked for. If something is still open, finish it. If you decided not to finish, do not report done: say plainly what stands in the way, with need_person or stuck.",
            sure * 100.0
        ))
    }
}

/// Asks whether the screen shows the task complete, in the task's own terms.
fn done_question(task: &Task) -> BTreeMap<String, Question> {
    let mut wording = format!("The task was: {}.", task.goal.trim());
    if !task.done_when.trim().is_empty() {
        wording.push_str(&format!(" It is done when the page shows: {}.", task.done_when.trim()));
    }
    let mut questions = BTreeMap::new();
    questions.insert(
        ASK_DONE.to_string(),
        Question::yes_no(format!(
            "{wording} Does this screen show that the task is complete: a confirmation, a thank-you, or the final state the task asked for? Answer no for a form still open or with fields to fill, an error message, a page that asks for something more, or a step on the way."
        )),
    );
    questions
}

/// The plan without the clicks the model named as the one that sends the page or goes on to the
/// next (and what follows each up to the next point), and those clicks.
fn without_commits(planned: &[Action]) -> (Vec<Action>, Vec<Action>) {
    let mut kept = Vec::new();
    let mut held = Vec::new();
    let mut dropping = false;
    for action in planned {
        if action.point().is_some() {
            dropping = action.commit != crate::action::Commit::None;
        }
        if dropping { held.push(action.clone()) } else { kept.push(action.clone()) }
    }
    (kept, held)
}

/// What a held click is called, for the model and the log.
fn name_of(click: &Action) -> String {
    let label = click.label.trim();
    if label.is_empty() { "the click that sends the page or goes on".to_string() } else { format!("{label:?}") }
}

/// Takes the click that sends the page or goes on out of a plan that lost part of itself, so the
/// page is not sent with something unfilled. The model is told, and presses the click on the
/// look after, when the page is complete.
fn hold_commits_lost(s: &mut Session, planned: &mut Vec<Action>, dropped: &mut Vec<String>, lost: usize) {
    if lost == 0 {
        return;
    }
    let (kept, held) = without_commits(planned);
    if held.is_empty() {
        return;
    }
    *planned = kept;
    dropped.push(format!("{} was held back: the plan lost {}", name_of(&held[0]), prompt::count(lost, "action")));
    s.notes.push(format!(
        "The harness did not press {} because {} of your plan could not be carried out, and the page is not complete. Plan what is left, and press it when nothing on the page is empty or wrong.",
        name_of(&held[0]),
        prompt::count(lost, "action")
    ));
    s.survey_again = true;
}

/// Takes the clicks that send the page or go on out of a plan while the to-do list still has a
/// required field empty on the page, even one the same plan fills: the click goes out on a later
/// look, once a survey shows the list clear. A field the model cannot fill does not hold the
/// page for ever: [`MAX_LIST_HOLDS`] times on one page.
fn hold_for_list(s: &mut Session, obs: &Observation, planned: &mut Vec<Action>, dropped: &mut Vec<String>) {
    let left: Vec<String> = s.empty_fields_on(&obs.url).iter().map(|n| n.to_string()).collect();
    if left.is_empty() {
        return;
    }
    let (kept, held) = without_commits(planned);
    if held.is_empty() {
        return;
    }
    let url = without_fragment(&obs.url).to_string();
    if s.list_hold.url != url {
        s.list_hold = ListHold { url, count: 0 };
    }
    if s.list_hold.count >= MAX_LIST_HOLDS {
        return;
    }
    s.list_hold.count += 1;
    *planned = kept;
    dropped.push(format!(
        "{} was held back ({} with it): the to-do list still has {} empty",
        name_of(&held[0]),
        prompt::count(held.len() - 1, "later action"),
        prompt::count(left.len(), "field")
    ));
    s.notes.push(format!(
        "The harness did not press the button that sends this page or goes on: your to-do list still has these required fields empty: {}. The rest of your plan ran. Look at each of them on the survey; when the list shows every required field filled, press the button, alone or after what is left.",
        quoted(&left)
    ));
    s.survey_again = true;
}

/// Takes the click that commits something beyond the page out of the first plan after the page
/// refused one, so the fields the page named are set and seen set before the page is sent again.
fn hold_refused_send(s: &mut Session, planned: &mut Vec<Action>, dropped: &mut Vec<String>) {
    if !s.send_refused {
        return;
    }
    s.send_refused = false;
    let Some(at) = planned.iter().position(|a| a.commit.irreversible().is_some()) else { return };
    let held = planned.split_off(at);
    dropped.push(format!(
        "{} was held back ({} with it): the page refused the last send, and the fields it named are set first",
        name_of(&held[0]),
        prompt::count(held.len() - 1, "later action")
    ));
    s.survey_again = true;
}

impl Session {
    /// Remembers the click that sends the page or goes on when the plan keeps one.
    pub(crate) fn note_commit_planned(&mut self, planned: &[Action], obs: &Observation) {
        if let Some(click) = planned.iter().find(|a| a.commit != crate::action::Commit::None) {
            self.commit = CommitState { id: click.id.clone(), url: without_fragment(&obs.url).to_string(), done: false, send: click.commit.irreversible().is_some() };
        }
    }

    /// Records that the click that sends the page went through, when its result came.
    pub(crate) fn note_commit_results(&mut self, results: &[crate::observe::ActionResult]) {
        if self.commit.id.is_empty() || self.commit.done {
            return;
        }
        if results.iter().any(|r| r.id == self.commit.id && r.ok) {
            self.commit.done = true;
        }
    }
}

/// Names in quotes, in a list.
fn quoted(names: &[String]) -> String {
    names.iter().map(|name| format!("{name:?}")).collect::<Vec<_>>().join(", ")
}

fn or_none(text: &str) -> &str {
    if text.is_empty() { "(none)" } else { text }
}

/// What the checker sees: the screenshot, or every screen of the survey when the look is one, so
/// what is anywhere on the page counts.
pub(crate) fn page_state(obs: &Observation) -> Vec<Part> {
    if obs.survey.is_empty() {
        return vec![Part::Text("A screenshot of a web page the browser is on.".to_string()), Part::Image(obs.screenshot.clone())];
    }
    let mut parts = vec![Part::Text("Screenshots of a web page the browser is on, from its top to its bottom.".to_string())];
    parts.extend(obs.survey.iter().map(|screen| Part::Image(screen.screenshot.clone())));
    parts
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::Profile;
    use crate::run::Config;
    use crate::task::Irreversible;
    use crate::testing::{Replying, Sure, look};

    #[test]
    fn a_done_the_screen_does_not_show_is_sent_back_then_ends_unconfirmed() {
        let reply = r#"{"status":"done","message":"Sent.","actions":[]}"#;
        let (model, seen) = Replying::new(reply);
        let agent = Agent::new(Config { done_passes: 1, max_stale: 100, ..Config::default() }, model).with_decider(Sure::of(&[(ASK_DONE, 0.2)]));
        let id = agent.start(Task::new("send the form"), Profile::default());
        let first = agent.step(&id, look(false, &[])).unwrap();
        assert_eq!(first.status, Status::Working);
        assert_eq!(first.message, DONE_PASS_MESSAGE);
        assert!(matches!(first.actions[0].kind, Kind::Wait { .. }));
        let second = agent.step(&id, look(true, &[])).unwrap();
        assert_eq!(second.status, Status::Stuck);
        assert_eq!(second.stop.unwrap().reason, StopReason::NotConfirmed);
        assert!(seen.lock().unwrap()[1].contains("You reported done, but the screen does not show that the task is done (a checker read it, 20% sure it did)."));
        // A checker that confirms the screen lets the done stand.
        let (model, _) = Replying::new(reply);
        let agent = Agent::new(Config::default(), model).with_decider(Sure::of(&[(ASK_DONE, 0.9)]));
        let id = agent.start(Task::new("send the form"), Profile::default());
        assert_eq!(agent.step(&id, look(false, &[])).unwrap().status, Status::Done);
    }

    #[test]
    fn a_stop_is_sent_back_once_to_finish_the_page_and_a_reason_the_policy_bars_is_refused() {
        let reply = r#"{"status":"need_person","message":"Your turn.","stop":{"reason":"other","problem":"A thing.","action":"Do it."},"actions":[]}"#;
        let (model, seen) = Replying::new(reply);
        let agent = Agent::new(Config { max_stale: 100, ..Config::default() }, model);
        let id = agent.start(Task::new("fill the form"), Profile::default());
        let first = agent.step(&id, look(false, &[])).unwrap();
        assert_eq!((first.status, first.message.as_str()), (Status::Working, STOP_PASS_MESSAGE));
        // The whole page was seen: the second stop stands.
        assert_eq!(agent.step(&id, look(true, &[])).unwrap().status, Status::NeedPerson);
        assert!(seen.lock().unwrap()[1].contains("You asked to stop for the person (other), but the person is asked last."));

        let (model, seen) = Replying::new(reply);
        let agent = Agent::new(Config { max_stale: 100, ..Config::default() }, model);
        let mut task = Task::new("fill the form");
        task.persistence = crate::task::Persistence::relentless();
        let id = agent.start(task, Profile::default());
        agent.step(&id, look(false, &[])).unwrap();
        assert_eq!(agent.step(&id, look(true, &[])).unwrap().status, Status::Working);
        assert!(seen.lock().unwrap()[1].contains("You asked to stop (other), but under this task's rules that is not a reason to stop"));
    }

    #[test]
    fn a_click_the_person_must_allow_is_held_and_asked_about_and_one_they_reserved_ends_the_run_ready() {
        let plan = r#"{"status":"working","message":"Sending.","actions":[{"kind":"click","x":10,"y":10,"label":"Name"},{"kind":"type","text":"A"},{"kind":"click","x":10,"y":40,"label":"Send","commit":"send"},{"kind":"wait","ms":500}]}"#;
        let (model, seen) = Replying::new(plan);
        let agent = Agent::new(Config { max_stale: 100, ..Config::default() }, model);
        let id = agent.start(Task::new("send the form"), Profile::default());
        let first = agent.step(&id, look(false, &[])).unwrap();
        assert_eq!(first.actions.len(), 2);
        assert_eq!(first.dropped, vec!["\"Send\" was held back (1 later action with it): the person is asked first whether the run may send or submit"]);
        assert_eq!(first.questions[0].allows, Some(Irreversible::Send));
        agent.answer(&id, &first.questions[0].id, "Yes.").unwrap();
        let second = agent.step(&id, look(true, &[])).unwrap();
        assert_eq!(second.actions.len(), 4);
        assert!(second.questions.is_empty());
        assert!(seen.lock().unwrap()[1].contains("The person allows you to send or submit on their behalf"));

        let (model, _) = Replying::new(plan);
        let agent = Agent::new(Config { max_stale: 100, ..Config::default() }, model);
        let id = agent.start(Task::new("send the form").allow(Irreversible::Send, Allowance::Never), Profile::default());
        assert_eq!(agent.step(&id, look(false, &[])).unwrap().actions.len(), 2);
        agent.forbid(&id, Irreversible::Send).unwrap();
        // Nothing else left but the reserved click: the run ends ready for the person.
        let (model, _) = Replying::new(r#"{"status":"working","message":"","actions":[{"kind":"click","x":10,"y":40,"label":"Send","commit":"send"}]}"#);
        let agent = Agent::new(Config { max_stale: 100, ..Config::default() }, model);
        let id = agent.start(Task::new("send the form").allow(Irreversible::Send, Allowance::Never), Profile::default());
        let step = agent.step(&id, look(false, &[])).unwrap();
        assert_eq!(step.status, Status::NeedPerson);
        assert_eq!(step.stop.unwrap().reason, StopReason::Reserved);
        assert!(step.actions.is_empty());
    }

    #[test]
    fn the_send_is_held_while_the_list_has_a_field_empty_or_the_plan_lost_actions() {
        use crate::observe::SurveyScreen;
        // The model reads a required field as empty, then plans the send: the send waits.
        let reply = r#"{"status":"working","message":"","fields":[{"label":"Email","screen":1,"y":20,"state":"empty"}],
            "actions":[{"kind":"click","screen":1,"x":10,"y":10,"label":"Name"},{"kind":"type","text":"A"},{"kind":"click","screen":1,"x":10,"y":40,"label":"Send","commit":"send"}]}"#;
        let (model, seen) = Replying::new(reply);
        let agent = Agent::new(Config { max_stale: 100, ..Config::default() }, model);
        let id = agent.start(Task::new("send the form").allow(Irreversible::Send, Allowance::Auto), Profile::default());
        let survey = || {
            let mut obs = look(false, &[]);
            obs.survey = vec![SurveyScreen { screenshot: obs.screenshot.clone(), scroll_y: 0.0 }];
            obs
        };
        // Even a field the same plan fills holds the send: it goes out once a survey shows the
        // list clear.
        let first = agent.step(&id, survey()).unwrap();
        assert_eq!(first.actions.len(), 2);
        assert_eq!(first.dropped, vec!["\"Send\" was held back (0 later actions with it): the to-do list still has 1 field empty"]);
        assert_eq!(agent.step(&id, survey()).unwrap().actions.len(), 2);
        assert!(seen.lock().unwrap()[1].contains("your to-do list still has these required fields empty: \"Email\"."));
        // A plan that lost an action (a point off the screen) does not press the send either.
        let reply = r#"{"status":"working","message":"","actions":[{"kind":"click","x":900,"y":10,"label":"Name"},{"kind":"click","x":10,"y":40,"label":"Send","commit":"send"}]}"#;
        let (model, _) = Replying::new(reply);
        let agent = Agent::new(Config::default(), model);
        let id = agent.start(Task::new("send the form").allow(Irreversible::Send, Allowance::Auto), Profile::default());
        let step = agent.step(&id, look(false, &[])).unwrap();
        assert!(step.dropped.iter().any(|d| d == "\"Send\" was held back: the plan lost 1 action"), "{:?}", step.dropped);
        assert!(matches!(step.actions[0].kind, Kind::Wait { .. }));
    }
}
