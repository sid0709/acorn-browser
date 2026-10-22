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

use std::collections::BTreeMap;
use std::time::SystemTime;

use crate::action::{Action, Kind};
use crate::model::Reply;
use crate::observe::Observation;
use crate::ports::{Decision, Part, Question};
use crate::run::{Agent, Status, StopInfo};
use crate::session::Session;
use crate::task::{StopReason, Task};
use crate::trace::ModelCall;

/// What the person sees while the harness makes the model look again.
pub const DONE_PASS_MESSAGE: &str = "The page has not confirmed the task is done; looking again.";
/// How long the model waits before it looks again, as the page may still be moving.
pub const PASS_WAIT_MS: u64 = 300;
/// The key of the question whether the screen shows the task done.
const ASK_DONE: &str = "done";

impl Agent {
    /// Applies the rules to the model's reply before its plan goes out. `number` names the step,
    /// for an action the gate puts in.
    pub(crate) fn gate(&self, s: &mut Session, obs: &Observation, reply: &mut Reply, planned: &mut Vec<Action>, _dropped: &mut Vec<String>, number: u32) {
        if let Some(note) = self.hold_done(s, obs, reply) {
            reply.status = Status::Working;
            reply.message = DONE_PASS_MESSAGE.to_string();
            *planned = vec![Action::new(format!("s{number}a1"), Kind::Wait { ms: PASS_WAIT_MS })];
            s.notes.push(note);
        }
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
}
