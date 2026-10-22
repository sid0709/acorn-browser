//! The loop: one step from an observation to the next batch of actions, with the stall checks,
//! the gate slot, and the end of the run.

use std::collections::HashMap;
use std::fmt;
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::action::{Action, Kind};
use crate::change;
use crate::gate::Gate;
use crate::model::{self, REPLY_SCHEMA_NAME};
use crate::observe::{ActionResult, Observation};
use crate::ports::{Browser, Error, Message, Model, ModelRequest, Role, Usage};
use crate::profile::Profile;
use crate::session::Session;
use crate::task::{StopReason, Task};

/// The knobs of the loop.
#[derive(Clone, Debug)]
pub struct Config {
    /// The most actions one reply may plan.
    pub max_actions: usize,
    /// The most actions that go out without a check of the screen between them.
    pub unchecked_actions: usize,
    /// How many steps in a row the screen may stay the same before the run ends as stuck.
    pub max_stale: u32,
    /// How many model steps in a row may end with every action failing the same way before the
    /// run ends as stuck. 0 turns the check off.
    pub max_failed_steps: u32,
}

impl Default for Config {
    fn default() -> Self {
        Config { max_actions: 30, unchecked_actions: 6, max_stale: 6, max_failed_steps: 3 }
    }
}

/// What the run does next.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    /// Carry out the actions and send the next look.
    #[default]
    Working,
    /// The task is complete.
    Done,
    /// Something only the person can do.
    NeedPerson,
    /// The run cannot make progress.
    Stuck,
}

/// Why a run ended without being done: what the person must do, in their words.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StopInfo {
    pub reason: StopReason,
    /// What is in the way.
    pub problem: String,
    /// What the person can do about it.
    pub action: String,
}

/// The harness's answer to one look: what to do next, and how the run stands.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Step {
    pub status: Status,
    /// One line for the person.
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop: Option<StopInfo>,
    /// Run in order; then the browser sends a new look.
    pub actions: Vec<Action>,
    /// This step's place in the run, from 1.
    pub number: u32,
    pub usage: Usage,
    /// Which actions the harness refused to send, and why.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dropped: Vec<String>,
    /// Asks the browser to make its next look a survey of the whole page.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub survey: bool,
}

/// Why a step could not be answered.
#[derive(Debug)]
pub enum StepError {
    NoSession,
    SessionOver,
    BadObservation(String),
    Model(Error),
    Reply(String),
    Browser(Error),
}

impl fmt::Display for StepError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StepError::NoSession => write!(f, "no such session"),
            StepError::SessionOver => write!(f, "the run has ended"),
            StepError::BadObservation(why) => write!(f, "bad observation: {why}"),
            StepError::Model(err) => write!(f, "model: {err}"),
            StepError::Reply(why) => write!(f, "reply: {why}"),
            StepError::Browser(err) => write!(f, "browser: {err}"),
        }
    }
}

impl std::error::Error for StepError {}

/// Runs tasks. It holds no state beyond its live sessions, so any number of runs go at once,
/// each on its own session.
pub struct Agent {
    config: Config,
    model: Box<dyn Model + Send + Sync>,
    gate: Gate,
    sessions: Mutex<HashMap<String, Arc<Mutex<Session>>>>,
}

impl Agent {
    pub fn new(config: Config, model: Box<dyn Model + Send + Sync>) -> Self {
        Agent { config, model, gate: Gate, sessions: Mutex::new(HashMap::new()) }
    }

    /// Begins a run and returns its id.
    pub fn start(&self, task: Task, profile: Profile) -> String {
        let session = Session::new(task, profile);
        let id = session.id.clone();
        self.sessions.lock().unwrap().insert(id.clone(), Arc::new(Mutex::new(session)));
        id
    }

    pub fn has(&self, id: &str) -> bool {
        self.sessions.lock().unwrap().contains_key(id)
    }

    /// Forgets a run.
    pub fn end(&self, id: &str) {
        self.sessions.lock().unwrap().remove(id);
    }

    /// Lets a run that ended go on, with a whole step budget more. The next look is answered as
    /// usual; the person may have done part of the page by hand in between.
    pub fn resume(&self, id: &str) -> Result<(), StepError> {
        let session = self.sessions.lock().unwrap().get(id).cloned().ok_or(StepError::NoSession)?;
        session.lock().unwrap().extend();
        Ok(())
    }

    /// Answers one look with the next actions.
    pub fn step(&self, id: &str, obs: Observation) -> Result<Step, StepError> {
        let session = self.sessions.lock().unwrap().get(id).cloned().ok_or(StepError::NoSession)?;
        let mut s = session.lock().unwrap();
        self.step_locked(&mut s, obs)
    }

    fn step_locked(&self, s: &mut Session, obs: Observation) -> Result<Step, StepError> {
        s.touch();
        if s.finished {
            return Err(StepError::SessionOver);
        }
        s.seq += 1;
        if !obs.viewport.has_size() {
            return Err(StepError::BadObservation("the viewport has no size".to_string()));
        }
        let (sig, width, height) = change::signature(&obs.screenshot).map_err(StepError::BadObservation)?;
        // The model measures coordinates in the image it is shown. If the image is not the size
        // the viewport says, every point it gives would land somewhere else on the page.
        if width.abs_diff(obs.viewport.width) > change::SIZE_TOLERANCE || height.abs_diff(obs.viewport.height) > change::SIZE_TOLERANCE {
            return Err(StepError::BadObservation(format!(
                "the screenshot is {width}x{height} pixels but the viewport says {}x{}",
                obs.viewport.width, obs.viewport.height
            )));
        }
        let results: Vec<ActionResult> = s.carried.iter().cloned().chain(obs.results.iter().cloned()).collect();
        if s.at_step_limit() {
            return Ok(end(
                s,
                Status::Stuck,
                format!("The run reached its limit of {} steps.", s.step_limit),
                StopInfo {
                    reason: StopReason::StepLimit,
                    problem: format!("This task took more than {} steps, so the run stopped.", s.step_limit),
                    action: "Finish the rest yourself, or let the run go on with more steps.".to_string(),
                },
            ));
        }
        // A page that did not move after actions is evidence the model needs, and a run that
        // never moves is not worth more model calls. A survey scrolls the page and comes back:
        // the same screen again is expected, not a stall.
        let mut stale = 0;
        if s.step > 0 && obs.survey.is_empty() && change::unchanged(&sig, s.last_signature.as_deref().unwrap_or(&[])) {
            stale = s.stale + 1;
        }
        if stale >= self.config.max_stale {
            return Ok(end(
                s,
                Status::Stuck,
                format!("The page did not change for {stale} steps in a row."),
                StopInfo {
                    reason: StopReason::NoChange,
                    problem: "The page stopped responding to the run's clicks and typing.".to_string(),
                    action: "Check the page for anything in the way, then let the run go on.".to_string(),
                },
            ));
        }
        // A plan refused whole, the same way, step after step, is a loop the model cannot see out
        // of: the page changes a little each time (a list opens, a cursor moves), so the
        // unchanged-screen count above never trips. The run ends before the model plans it again.
        let failure = first_failure(&results);
        let streak = if failure.is_empty() {
            0
        } else if failure == s.last_failure {
            s.failed_streak + 1
        } else {
            1
        };
        if self.config.max_failed_steps > 0 && streak >= self.config.max_failed_steps {
            return Ok(end(
                s,
                Status::Stuck,
                format!("The same action failed {streak} steps in a row: {failure}"),
                StopInfo {
                    reason: StopReason::RepeatedFailure,
                    problem: format!("The run tried the same step {streak} times and the page would not take it: {failure}"),
                    action: "Do that part on the page yourself, then let the run go on.".to_string(),
                },
            ));
        }
        let number = s.step + 1;

        let text = model::observation_text(number, s.step_limit, &obs, &results, &s.notes, &s.memo, stale);
        let images = if obs.survey.is_empty() {
            vec![obs.screenshot.clone()]
        } else {
            obs.survey.iter().map(|screen| screen.screenshot.clone()).collect()
        };
        let messages = vec![
            Message { role: Role::System, text: model::system_prompt(&s.task, &s.profile), images: Vec::new(), cache: true },
            Message { role: Role::User, text, images, cache: false },
        ];
        let response = self
            .model
            .complete(ModelRequest { messages, schema_name: REPLY_SCHEMA_NAME.to_string(), schema: model::reply_schema() })
            .map_err(StepError::Model)?;
        s.usage.add(response.usage);
        let mut reply = model::parse_reply(&response.content).map_err(StepError::Reply)?;

        // Only a step the model answered counts: a retry of a failed call sends the same screen.
        s.step = number;
        s.stale = stale;
        s.last_signature = Some(sig);
        s.failed_streak = streak;
        s.last_failure = failure;
        s.carried.clear();
        s.notes.clear();
        if let Some(memo) = reply.memo.take() {
            s.memo = clip(memo.trim(), model::MAX_MEMO_CHARS);
        }

        let mut dropped = Vec::new();
        let (mut planned, survey_asked) = self.check_actions(number, std::mem::take(&mut reply.actions), &obs, &mut dropped);
        let survey_asked = survey_asked && s.task.survey;
        self.gate.apply(s, &obs, &mut reply, &mut planned, &mut dropped);

        let actions = if reply.status != Status::Working {
            Vec::new()
        } else {
            if planned.len() > self.config.unchecked_actions {
                dropped.push(format!(
                    "{} actions were not sent: only {} run without a check",
                    planned.len() - self.config.unchecked_actions,
                    self.config.unchecked_actions
                ));
                planned.truncate(self.config.unchecked_actions);
            }
            if planned.is_empty() && !survey_asked {
                // A working run with nothing valid to do waits and looks again.
                dropped.push("no usable action; waiting before the next look".to_string());
                planned.push(Action::new(format!("s{number}a1"), Kind::Wait { ms: 1000 }));
            }
            planned
        };

        let step = Step {
            status: reply.status,
            message: reply.message.trim().to_string(),
            stop: if reply.status == Status::Working { None } else { reply.stop.clone() },
            actions,
            number,
            usage: s.usage,
            dropped,
            survey: reply.status == Status::Working && survey_asked,
        };
        if step.status != Status::Working {
            s.finished = true;
        }
        Ok(step)
    }

    /// Keeps the actions the browser can carry out: at most `max_actions`, each at a point
    /// inside the screenshot, named by the harness. A survey request is taken out and reported.
    fn check_actions(&self, number: u32, actions: Vec<Action>, obs: &Observation, dropped: &mut Vec<String>) -> (Vec<Action>, bool) {
        let mut out = Vec::new();
        let mut survey_asked = false;
        let width = obs.viewport.width as f64;
        let height = obs.viewport.height as f64;
        for (i, mut action) in actions.into_iter().enumerate() {
            if out.len() >= self.config.max_actions {
                dropped.push(format!("action {} and after: at most {} actions a step", i + 1, self.config.max_actions));
                break;
            }
            if matches!(action.kind, Kind::Survey) {
                survey_asked = true;
                continue;
            }
            if let Some(p) = action.point()
                && !(p.x >= 0.0 && p.x <= width && p.y >= 0.0 && p.y <= height)
            {
                dropped.push(format!("action {}: the point ({:.0}, {:.0}) lies outside the {}x{} screenshot", i + 1, p.x, p.y, obs.viewport.width, obs.viewport.height));
                continue;
            }
            action.id = format!("s{number}a{}", out.len() + 1);
            out.push(action);
        }
        (out, survey_asked)
    }
}

/// Runs a session to its end against a browser: look, step, act, and look again with the results,
/// until the run is no longer working. Returns the step that ended it.
pub fn drive(agent: &Agent, id: &str, browser: &mut dyn Browser) -> Result<Step, StepError> {
    let mut results = Vec::new();
    let mut survey = false;
    loop {
        let mut obs = browser.observe(survey).map_err(StepError::Browser)?;
        obs.results = std::mem::take(&mut results);
        let step = agent.step(id, obs)?;
        if step.status != Status::Working {
            return Ok(step);
        }
        results = browser.act(&step.actions).map_err(StepError::Browser)?;
        survey = step.survey;
    }
}

/// The error of the first action of the batch that failed, when nothing in it succeeded; empty
/// when something did, or nothing was planned. An action that reached no control is not a
/// failure of the batch, and what was skipped after a failure says nothing of its own.
fn first_failure(results: &[ActionResult]) -> String {
    let mut first = String::new();
    for result in results {
        if result.ok {
            return String::new();
        }
        if first.is_empty() && !result.unreached && !result.error.is_empty() {
            first = result.error.clone();
        }
    }
    first
}

/// Ends the run with no actions: the person is told why and what they can do.
fn end(s: &mut Session, status: Status, message: String, stop: StopInfo) -> Step {
    s.finished = true;
    Step { status, message, stop: Some(stop), actions: Vec::new(), number: s.step, usage: s.usage, dropped: Vec::new(), survey: false }
}

fn clip(text: &str, max_chars: usize) -> String {
    match text.char_indices().nth(max_chars) {
        Some((end, _)) => text[..end].to_string(),
        None => text.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::observe::Viewport;
    use crate::ports::ModelResponse;

    struct Fixed(&'static str);

    impl Model for Fixed {
        fn complete(&self, _request: ModelRequest) -> Result<ModelResponse, Error> {
            Ok(ModelResponse { content: self.0.to_string(), ..Default::default() })
        }
        fn name(&self) -> &str {
            "fixed"
        }
    }

    fn look() -> Observation {
        Observation {
            screenshot: change::test_screenshot(80, 60, false),
            viewport: Viewport { width: 80, height: 60, ..Default::default() },
            ..Default::default()
        }
    }

    #[test]
    fn a_screen_that_never_changes_ends_the_run() {
        let reply = r#"{"status":"working","message":"","actions":[{"kind":"wait","ms":100}]}"#;
        let agent = Agent::new(Config { max_stale: 2, ..Config::default() }, Box::new(Fixed(reply)));
        let id = agent.start(Task::new("wait"), Profile::default());
        assert_eq!(agent.step(&id, look()).unwrap().status, Status::Working);
        assert_eq!(agent.step(&id, look()).unwrap().status, Status::Working);
        let third = agent.step(&id, look()).unwrap();
        assert_eq!(third.status, Status::Stuck);
        assert_eq!(third.stop.unwrap().reason, StopReason::NoChange);
        let mut wrong = look();
        wrong.viewport.width = 500;
        let agent = Agent::new(Config::default(), Box::new(Fixed(reply)));
        let id = agent.start(Task::new("wait"), Profile::default());
        assert!(matches!(agent.step(&id, wrong), Err(StepError::BadObservation(_))));
    }

    #[test]
    fn a_step_names_the_actions_and_drops_points_off_screen() {
        let reply = r#"{"observation":"a form","memo":"first look","status":"working","message":"Filling the form.","stop":null,
            "actions":[{"kind":"click","x":10,"y":20},{"kind":"type","text":"hi"},{"kind":"click","x":900,"y":20}]}"#;
        let agent = Agent::new(Config::default(), Box::new(Fixed(reply)));
        let id = agent.start(Task::new("fill the form"), Profile::default());
        let step = agent.step(&id, look()).unwrap();
        assert_eq!(step.status, Status::Working);
        assert_eq!(step.number, 1);
        let ids: Vec<&str> = step.actions.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, vec!["s1a1", "s1a2"]);
        assert_eq!(step.dropped.len(), 1);
        assert!(agent.has(&id));
    }

    #[test]
    fn the_step_limit_ends_the_run_and_resume_adds_a_budget() {
        let reply = r#"{"status":"working","message":"","actions":[{"kind":"wait","ms":100}]}"#;
        let agent = Agent::new(Config::default(), Box::new(Fixed(reply)));
        let mut task = Task::new("go on for ever");
        task.persistence.max_steps = 2;
        let id = agent.start(task, Profile::default());
        assert_eq!(agent.step(&id, look()).unwrap().status, Status::Working);
        assert_eq!(agent.step(&id, look()).unwrap().status, Status::Working);
        let third = agent.step(&id, look()).unwrap();
        assert_eq!(third.status, Status::Stuck);
        assert_eq!(third.stop.unwrap().reason, StopReason::StepLimit);
        assert!(third.actions.is_empty());
        agent.resume(&id).unwrap();
        assert_eq!(agent.step(&id, look()).unwrap().status, Status::Working);
    }

    #[test]
    fn the_same_failure_step_after_step_ends_the_run() {
        let reply = r#"{"status":"working","message":"","actions":[{"kind":"click","x":5,"y":5}]}"#;
        let agent = Agent::new(Config { max_failed_steps: 2, max_stale: 100, ..Config::default() }, Box::new(Fixed(reply)));
        let id = agent.start(Task::new("click"), Profile::default());
        let refused = |id: &str| ActionResult { id: id.into(), ok: false, error: "the page refused the click".into(), ..Default::default() };
        assert_eq!(agent.step(&id, look()).unwrap().status, Status::Working);
        let mut second = look();
        second.results = vec![refused("s1a1")];
        assert_eq!(agent.step(&id, second).unwrap().status, Status::Working);
        let mut third = look();
        third.results = vec![refused("s2a1")];
        let step = agent.step(&id, third).unwrap();
        assert_eq!(step.status, Status::Stuck);
        assert_eq!(step.stop.unwrap().reason, StopReason::RepeatedFailure);
        assert_eq!(first_failure(&[refused("a"), ActionResult { id: "b".into(), ok: true, ..Default::default() }]), "");
    }

    #[test]
    fn a_done_reply_ends_the_run() {
        let reply = r#"{"status":"done","message":"Sent."}"#;
        let agent = Agent::new(Config::default(), Box::new(Fixed(reply)));
        let id = agent.start(Task::new("send it"), Profile::default());
        assert_eq!(agent.step(&id, look()).unwrap().status, Status::Done);
        assert!(matches!(agent.step(&id, look()), Err(StepError::SessionOver)));
    }
}
