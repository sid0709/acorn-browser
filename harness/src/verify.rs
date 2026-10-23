//! Checking what happened without blocking what happens next: a checkpoint after each batch of a
//! plan, so the next batch can run without the driving model looking again.
//!
//! The driving model plans a whole screen at once and says, at the end of each batch it is sure
//! of, what the screen should then show. A decision model (cheap and quick, answering with
//! probabilities and no prose) reads the screenshot after that batch. When the screen matches,
//! the next batch goes out without the driving model; when it does not, or something is in the
//! way, the driving model looks and decides. The driving model is the only one that ever plans
//! or recovers: the checker only says yes or no.

use crate::action::{self, Action, Batch, Kind};
use crate::change::Signature;
use crate::memory;
use crate::observe::{ActionResult, Observation};
use crate::prompt;
use crate::review;
use crate::ports::{Decider, Decision, Error, Part, Question, Verdicts};
use crate::run::{Agent, Status, Step};
use crate::session::Session;
use crate::trace::{CheckTrace, ModelCall};

/// The keys the checker's answers come back under.
pub const ASK_MATCHES: &str = "matches";
pub const ASK_CONTRADICTED: &str = "contradicted";
pub const ASK_BLOCKED: &str = "blocked";
pub const ASK_LOADING: &str = "loading";

/// What the checker made of a screenshot: the probability of each of its questions. "Matches"
/// and "contradicted" are asked apart, because a screen can show neither: a focus, a menu that
/// closed, a change too small to see. Not seeing is not seeing otherwise.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Verdict {
    pub matches: f64,
    pub contradicted: f64,
    pub blocked: f64,
    pub loading: f64,
}

/// The thresholds that turn a verdict into an outcome.
#[derive(Clone, Copy, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Thresholds {
    /// At or above this, the screen matches what was expected.
    pub match_at: f64,
    /// Above this, the screen shows otherwise than expected: the plan is given up. Below it,
    /// with no match either, the checker could not tell: the model looks, with the plan kept.
    pub contradicted_over: f64,
    /// Above this, something is in the way.
    pub blocked_over: f64,
    /// Above this, the page may still be loading.
    pub loading_over: f64,
    /// At or above this, the page is loading enough to wait for it.
    pub loading_wait_at: f64,
    /// The most waits in a row for a loading page before the model looks instead.
    pub max_load_waits: u32,
}

impl Default for Thresholds {
    fn default() -> Self {
        Thresholds { match_at: 0.9, contradicted_over: 0.6, blocked_over: 0.2, loading_over: 0.3, loading_wait_at: 0.7, max_load_waits: 4 }
    }
}

/// What a checked screen means for the plan.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The screen shows what was expected: run the next batch without the model.
    Continue,
    /// The page is still loading: wait and check again.
    Wait,
    /// Give the screenshot to the driving model, for this reason; the plan is given up.
    Look(String),
    /// The checker could not tell either way: the driving model looks, and the rest of the plan
    /// is kept for it to resume or replace.
    Unsure(String),
}

impl Outcome {
    /// The outcome as the trace names it.
    pub fn name(&self) -> &'static str {
        match self {
            Outcome::Continue => "continue",
            Outcome::Wait => "wait",
            Outcome::Look(_) => "model",
            Outcome::Unsure(_) => "unsure",
        }
    }
}

/// Asks the checker whether the screen shows what the model expected, whether it shows otherwise,
/// whether something is in the way, and whether the page is still loading. `evidence` is what
/// the page reports beside the picture (the focused control, the address, what became of the
/// actions): what a screenshot cannot show, the checker is told.
pub fn look(decider: &(dyn Decider + Send + Sync), screenshot: &str, evidence: &str, expect: &str) -> Result<(Verdict, Verdicts), Error> {
    let mut questions = std::collections::BTreeMap::new();
    questions.insert(
        ASK_MATCHES.to_string(),
        Question::yes_no(format!("Someone has just typed and clicked on this page. They expected the page to now show: {expect}. Does the screenshot, or the page's report beside it, show that?")),
    );
    questions.insert(
        ASK_CONTRADICTED.to_string(),
        Question::yes_no(format!("Does the screenshot, or the page's report beside it, show something that contradicts this expectation: {expect}? Answer yes only for positive evidence against it (the control plainly empty or unchanged, a message that it was refused, a different page than the one expected). Answer no when the screen simply does not show enough to tell.")),
    );
    questions.insert(
        ASK_BLOCKED.to_string(),
        Question::yes_no("Is the page blocked by something other than the content itself: a popup, dialog or overlay covering it, a CAPTCHA, a sign-in wall, or a page-level error such as 'something went wrong'? A small validation message beside a field does not count."),
    );
    questions.insert(
        ASK_LOADING.to_string(),
        Question::yes_no("Is the page still loading or changing: a spinner, a progress bar, a blank or half-drawn page, or a control that says it is still working?"),
    );
    let mut state = vec![Part::Text("A screenshot of a web page the browser is on.".to_string()), Part::Image(screenshot.to_string())];
    if !evidence.trim().is_empty() {
        state.push(Part::Text(format!("What the page itself reports, which the screenshot may not show:\n{}", evidence.trim())));
    }
    let verdicts = decider.decide(Decision { state, questions })?;
    let answer = |key: &str| verdicts.yes(key).ok_or_else(|| Error::new(crate::ports::ErrorKind::Other, format!("the checker gave no answer to {key:?}")));
    let verdict = Verdict {
        matches: answer(ASK_MATCHES)?,
        // A checker that does not know the question is taken as not contradicting.
        contradicted: verdicts.yes(ASK_CONTRADICTED).unwrap_or(0.0),
        blocked: answer(ASK_BLOCKED)?,
        loading: answer(ASK_LOADING)?,
    };
    Ok((verdict, verdicts))
}

/// What a verdict means: carry on with the plan, wait for the page, or give the screenshot to
/// the driving model.
pub fn judge(v: Verdict, t: &Thresholds, load_waits: u32) -> Outcome {
    if v.matches >= t.match_at && v.blocked <= t.blocked_over && v.loading <= t.loading_over {
        Outcome::Continue
    } else if v.loading >= t.loading_wait_at && load_waits < t.max_load_waits {
        Outcome::Wait
    } else if v.blocked > t.blocked_over {
        Outcome::Look(format!("something may be in the way ({:.2})", v.blocked))
    } else if v.loading > t.loading_over {
        Outcome::Look(format!("the page may still be loading ({:.2})", v.loading))
    } else if v.contradicted > t.contradicted_over {
        Outcome::Look(format!("the screen shows otherwise ({:.2} against, {:.2} for)", v.contradicted, v.matches))
    } else {
        Outcome::Unsure(format!("nothing on the screen or in the page's report settles it ({:.2} for, {:.2} against)", v.matches, v.contradicted))
    }
}

impl Agent {
    /// Whether a checker is wired in at all: a decision model, and batches of a size. The prompt
    /// and the reply schema follow this for the whole run.
    pub(crate) fn checks_available(&self) -> bool {
        self.decider.is_some() && self.config.chunk_actions > 0
    }

    /// Whether this run's screen is checked between batches: a checker is wired in and none of
    /// its checks has failed this run.
    pub(crate) fn checks_on(&self, s: &Session) -> bool {
        self.checks_available() && !s.checks_off
    }

    /// Stores a new plan and returns the first batch to send. A batch the model put no check on
    /// ends the plan there: the model looks next. Without a checker a plan is cut to the few
    /// actions that are safe to send without looking.
    pub(crate) fn take_plan(&self, s: &mut Session, mut actions: Vec<Action>, mut dropped: Vec<String>) -> (Vec<Action>, Vec<String>) {
        s.forget_plan();
        s.load_waits = 0;
        s.reviewed.clear();
        s.planned = actions.len();
        s.by_id = actions.iter().map(|a| (a.id.clone(), a.clone())).collect();
        if actions.is_empty() {
            return (actions, dropped);
        }
        if !self.checks_on(s) {
            let limit = self.config.unchecked_actions;
            if limit > 0 && actions.len() > limit {
                dropped.push(format!("{} actions were not sent: only {limit} run without a check", actions.len() - limit));
                actions.truncate(limit);
            }
            s.sent = actions.len();
            s.parts = 1;
            return (actions, dropped);
        }
        let batches = action::split_plan_for_checks(actions, self.config.chunk_actions, true);
        self.send_batch(s, batches, dropped)
    }

    /// Sends the first of the batches and keeps the rest only if the screen can be checked after
    /// it.
    pub(crate) fn send_batch(&self, s: &mut Session, batches: Vec<Batch>, mut dropped: Vec<String>) -> (Vec<Action>, Vec<String>) {
        let mut batches = batches.into_iter();
        let Some(first) = batches.next() else { return (Vec::new(), dropped) };
        let mut rest: Vec<Batch> = batches.collect();
        s.sent += first.actions.len();
        s.parts += 1;
        // The reviews of the zones ask only about what went out: a field the plan types into
        // later is not one the photo of this batch can show.
        s.sent_actions.extend(first.actions.iter().cloned());
        s.expect = review::expectations_of(&s.sent_actions, s.plan_scroll_y);
        if !rest.is_empty() && first.expect.is_empty() {
            let skipped: usize = rest.iter().map(|batch| batch.actions.len()).sum();
            dropped.push(format!("{skipped} planned actions were not sent: the batch before them had no check, so the model looks first"));
            s.notes.push(format!(
                "You planned {} actions: {} ran. The rest did not run because the actions before them had no check; look at the screen and plan again.",
                s.planned, s.sent
            ));
            rest.clear();
        }
        s.plan = rest;
        s.verify = first.expect;
        (first.actions, dropped)
    }

    /// Drops the rest of the plan and tells the model why on its next look. Every action withheld
    /// is recorded, so a run's trace shows what never went out and why.
    pub(crate) fn abandon(&self, s: &mut Session, reason: &str) {
        let left = s.planned.saturating_sub(s.sent);
        for action in s.plan.iter().flat_map(|batch| batch.actions.iter()) {
            s.withheld.push(format!("{} ({}) not sent: {reason}", action.id, memory::describe(action)));
        }
        // A plan that did not go as expected is over.
        s.plan.clear();
        s.verify.clear();
        if s.planned == 0 {
            return;
        }
        s.notes.push(format!("You planned {} actions: {} ran, {left} did not. {reason}", s.planned, s.sent));
    }

    /// Keeps the rest of the plan for the model to resume or replace, and tells it what is kept.
    pub(crate) fn suspend(&self, s: &mut Session, reason: &str) {
        s.verify.clear();
        let kept: Vec<String> = s.plan.iter().flat_map(|batch| batch.actions.iter()).map(|action| format!("{} {}", action.id, memory::describe(action))).collect();
        if kept.is_empty() {
            s.notes.push(format!("You planned {} actions: all ran. {reason}", s.planned));
            return;
        }
        s.notes.push(format!(
            "You planned {} actions: {} ran. {reason} The rest of your plan is kept, not run: {}. If the screen shows your plan still holds, answer with the single action {{\"kind\": \"resume\"}} and they run as planned; otherwise plan afresh and they are dropped.",
            s.planned,
            s.sent,
            kept.join("; ")
        ));
    }

    /// Runs the next batch of the model's plan if the screen shows what the model expected,
    /// without calling the model. `None` means the model must look instead. `results` are the
    /// results of every action sent since the model last looked.
    pub(crate) fn continue_plan(&self, s: &mut Session, obs: &Observation, results: &[ActionResult], sig: &Signature, stale: u32) -> Option<Step> {
        if s.verify.is_empty() || !self.checks_on(s) {
            return None;
        }
        let decider = self.decider.as_ref()?;
        let expect = s.verify.clone();
        let failed = failed_results(&obs.results);
        if !failed.is_empty() {
            self.abandon(s, &format!("The last actions failed: {failed}."));
            return None;
        }
        // A page that is loading may look the same for a moment; anything else that did not move
        // is not what the model expected. Typing and keys are the exception: a few characters in
        // a field move too few pixels to register as a change, so the checker is asked instead.
        if stale > 0 && s.load_waits == 0 && !changed_little(s, &obs.results) {
            self.abandon(s, "The screen did not change after them, so it is not what you expected.");
            return None;
        }
        let started = std::time::SystemTime::now();
        let evidence = prompt::evidence_text(obs, results);
        let looked = look(decider.as_ref(), &obs.screenshot, &evidence, &expect);
        s.pending_calls.push(ModelCall::decision(&format!("expected: {expect}"), looked.as_ref().map(|(_, verdicts)| verdicts), started));
        let (verdict, verdicts) = match looked {
            Ok(looked) => looked,
            Err(err) => {
                // A checker that fails is not worth asking again this run; the model looks instead.
                s.checks_off = true;
                s.last_check = Some(CheckTrace { expect, outcome: Outcome::Look(String::new()).name().to_string(), error: err.to_string(), ..Default::default() });
                self.abandon(s, "The screen could not be checked, so the rest of your plan did not run.");
                return None;
            }
        };
        s.usage.add(verdicts.usage);
        let outcome = judge(verdict, &self.config.checkpoint, s.load_waits);
        s.last_check = Some(CheckTrace {
            expect: expect.clone(),
            matches: verdict.matches,
            contradicted: verdict.contradicted,
            blocked: verdict.blocked,
            loading: verdict.loading,
            outcome: outcome.name().to_string(),
            reason: match &outcome {
                Outcome::Look(reason) | Outcome::Unsure(reason) => reason.clone(),
                _ => String::new(),
            },
            model: verdicts.model.clone(),
            latency_ms: verdicts.latency.as_millis() as i64,
            error: String::new(),
        });
        match outcome {
            Outcome::Continue => {
                s.carried = results.to_vec();
                s.stale = 0;
                s.last_signature = Some(sig.clone());
                s.load_waits = 0;
                s.verify.clear();
                if s.plan.is_empty() {
                    return None;
                }
                let plan = std::mem::take(&mut s.plan);
                let (actions, dropped) = self.send_batch(s, plan, Vec::new());
                let survey = self.survey_next(s, false);
                Some(Step { status: Status::Working, message: s.message.clone(), actions, number: s.step, usage: s.usage, dropped, survey, ..Default::default() })
            }
            Outcome::Wait => {
                s.load_waits += 1;
                s.stale = stale;
                s.last_signature = Some(sig.clone());
                s.carried = results.to_vec();
                let wait = Action::new(format!("s{}w{}", s.step, s.load_waits), Kind::Wait { ms: self.config.load_wait.as_millis() as u64 });
                Some(Step { status: Status::Working, message: s.message.clone(), actions: vec![wait], number: s.step, usage: s.usage, ..Default::default() })
            }
            Outcome::Look(reason) => {
                let mut text = format!("The checker did not confirm the screen showed what you expected ({expect}): {reason}.");
                if expect.starts_with(action::COMBINED_CHECK_PREFIX) {
                    // One of several fields failed its check, and the checker cannot say which:
                    // the model reads the screen and puts every wrong or empty field right in one
                    // answer, not one field per look.
                    text.push_str(" Look at every field on this screen now, and plan every one that is wrong or empty together in one answer.");
                }
                self.abandon(s, &text);
                None
            }
            Outcome::Unsure(reason) => {
                self.suspend(s, &format!("The checker could not tell whether the screen showed what you expected ({expect}): {reason}."));
                None
            }
        }
    }
}

/// Whether the last batch typed text or pressed a key: an edit the pixel comparison cannot be
/// trusted to see.
fn changed_little(s: &Session, results: &[ActionResult]) -> bool {
    results.iter().any(|result| matches!(s.by_id.get(&result.id).map(|action| &action.kind), Some(Kind::Type { .. } | Kind::Key { .. })))
}

/// Names the actions that failed, or is empty. An action that only reached no control is not a
/// failure of the batch: the batch went on past it.
fn failed_results(results: &[ActionResult]) -> String {
    results
        .iter()
        .filter(|result| !result.ok && !result.unreached)
        .map(|result| format!("{} {}", result.id, result.error).trim().to_string())
        .collect::<Vec<_>>()
        .join("; ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::Profile;
    use crate::run::Config;
    use crate::task::{Allowance, Irreversible, Task};
    use crate::testing::{Replying, Sure, look as look_at};
    use std::sync::{Arc, Mutex};

    /// A task whose send the run may press on its own.
    fn task() -> Task {
        Task::new("fill the form").allow(Irreversible::Send, Allowance::Auto)
    }

    /// An agent whose model always plans the same two batches and whose checker is this sure of
    /// a match, with the texts the model is sent.
    const PLAN: &str = r#"{"status":"working","message":"Filling.","actions":[
            {"kind":"click","x":10,"y":10,"label":"Name","check":"the Name field is focused"},
            {"kind":"type","text":"A. Person"},
            {"kind":"click","x":10,"y":50,"label":"Send","commit":"send","check":"a thank-you"}]}"#;

    fn agent(matches: f64) -> (Agent, Arc<Mutex<Vec<String>>>) {
        agent_sure(matches, 0.0)
    }

    /// An agent whose checker is this sure of a match and this sure of the opposite.
    fn agent_sure(matches: f64, contradicted: f64) -> (Agent, Arc<Mutex<Vec<String>>>) {
        let (model, seen) = Replying::new(PLAN);
        (Agent::new(Config::default(), model).with_decider(Sure::of(&[(ASK_MATCHES, matches), (ASK_CONTRADICTED, contradicted)])), seen)
    }

    /// A model that answers each call with the next of its replies, then repeats the last.
    struct Sequenced(Vec<&'static str>, Mutex<usize>, Arc<Mutex<Vec<String>>>);

    impl crate::ports::Model for Sequenced {
        fn complete(&self, request: crate::ports::ModelRequest) -> Result<crate::ports::ModelResponse, crate::ports::Error> {
            self.2.lock().unwrap().push(request.messages.last().map(|m| m.text.clone()).unwrap_or_default());
            let mut n = self.1.lock().unwrap();
            let reply = self.0[(*n).min(self.0.len() - 1)];
            *n += 1;
            Ok(crate::ports::ModelResponse { content: reply.to_string(), ..Default::default() })
        }
        fn name(&self) -> &str {
            "sequenced"
        }
    }

    fn ids(step: &Step) -> Vec<&str> {
        step.actions.iter().map(|a| a.id.as_str()).collect()
    }

    #[test]
    fn a_confirmed_checkpoint_sends_the_next_batch_without_the_model() {
        let (agent, seen) = agent(1.0);
        let id = agent.start(task(), Profile::default());
        let first = agent.step(&id, look_at(false, &[])).unwrap();
        assert_eq!(ids(&first), ["s1a1"]);
        let second = agent.step(&id, look_at(true, &["s1a1"])).unwrap();
        assert_eq!(ids(&second), ["s1a2", "s1a3"]);
        assert_eq!(second.number, 1);
        assert_eq!(seen.lock().unwrap().len(), 1);
        // The plan is spent: the model looks, told what became of every batch.
        let third = agent.step(&id, look_at(false, &["s1a2", "s1a3"])).unwrap();
        assert_eq!(third.number, 2);
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        assert!(seen[1].contains("- s1a1 done") && seen[1].contains("- s1a3 done"));
    }

    #[test]
    fn a_message_from_the_person_stops_a_running_plan_and_reaches_the_model() {
        let (agent, seen) = agent(1.0);
        let id = agent.start(task(), Profile::default());
        agent.step(&id, look_at(false, &[])).unwrap();
        agent.say(&id, "  use my work email instead ").unwrap();
        let second = agent.step(&id, look_at(true, &["s1a1"])).unwrap();
        assert_eq!(second.number, 2);
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        assert!(seen[1].contains("You planned 3 actions: 1 ran, 2 did not. The person wrote to you meanwhile"), "{}", seen[1]);
        assert!(seen[1].contains("- use my work email instead\n"), "{}", seen[1]);
    }

    #[test]
    fn a_checkpoint_the_screen_contradicts_gives_the_plan_up_and_the_model_looks() {
        let (agent, seen) = agent_sure(0.1, 0.9);
        let id = agent.start(task(), Profile::default());
        agent.step(&id, look_at(false, &[])).unwrap();
        let second = agent.step(&id, look_at(true, &["s1a1"])).unwrap();
        assert_eq!(second.number, 2);
        // The withheld actions are on the record of the step that followed.
        assert!(second.dropped.iter().any(|line| line.starts_with("s1a2 (type") && line.contains("not sent")), "{:?}", second.dropped);
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        assert!(seen[1].contains("You planned 3 actions: 1 ran, 2 did not. The checker did not confirm"), "{}", seen[1]);
        assert!(seen[1].contains("shows otherwise"), "{}", seen[1]);
    }

    #[test]
    fn an_unsure_check_keeps_the_plan_and_resume_runs_the_rest() {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let model = Sequenced(vec![PLAN, r#"{"status":"working","message":"Going on.","actions":[{"kind":"resume"}]}"#], Mutex::new(0), seen.clone());
        let agent = Agent::new(Config::default(), Box::new(model)).with_decider(Sure::of(&[(ASK_MATCHES, 0.1), (ASK_CONTRADICTED, 0.1)]));
        let id = agent.start(task(), Profile::default());
        let first = agent.step(&id, look_at(false, &[])).unwrap();
        assert_eq!(ids(&first), vec!["s1a1"]);
        let second = agent.step(&id, look_at(true, &["s1a1"])).unwrap();
        assert_eq!(second.number, 2);
        assert_eq!(ids(&second), vec!["s1a2", "s1a3"]);
        assert!(second.dropped.is_empty(), "{:?}", second.dropped);
        let seen = seen.lock().unwrap();
        assert!(seen[1].contains("could not tell") && seen[1].contains("is kept, not run: s1a2 type"), "{}", seen[1]);
    }

    #[test]
    fn a_clean_match_continues_and_doubt_looks() {
        let t = Thresholds::default();
        assert_eq!(judge(Verdict { matches: 0.95, contradicted: 0.0, blocked: 0.0, loading: 0.0 }, &t, 0), Outcome::Continue);
        assert_eq!(judge(Verdict { matches: 0.1, contradicted: 0.0, blocked: 0.0, loading: 0.9 }, &t, 0), Outcome::Wait);
        // Too many waits already: look instead.
        assert!(matches!(judge(Verdict { matches: 0.1, contradicted: 0.0, blocked: 0.0, loading: 0.9 }, &t, 4), Outcome::Look(_)));
        assert!(matches!(judge(Verdict { matches: 0.1, contradicted: 0.0, blocked: 0.9, loading: 0.0 }, &t, 0), Outcome::Look(_)));
        assert!(matches!(judge(Verdict { matches: 0.1, contradicted: 0.9, blocked: 0.0, loading: 0.0 }, &t, 0), Outcome::Look(_)));
        assert!(matches!(judge(Verdict { matches: 0.1, contradicted: 0.1, blocked: 0.0, loading: 0.0 }, &t, 0), Outcome::Unsure(_)));
    }
}
