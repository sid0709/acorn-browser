//! The loop: one step from an observation to the next batch of actions, with the stall checks,
//! the gate slot, and the end of the run.

use std::collections::HashMap;
use std::fmt;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::action::{self, Action, Kind};
use crate::change;
use crate::focus;
use crate::memory::{self, Turn};
use crate::gate::Gate;
use crate::model::{self, REPLY_SCHEMA_NAME};
use crate::prompt;
use crate::recover;
use crate::review;
use crate::observe::{self, ActionResult, Observation};
use crate::ports::{Browser, Decider, Error, ErrorKind, Message, Model, Role, Usage};
use crate::profile::Profile;
use crate::session::Session;
use crate::task::{StopReason, Task};
use crate::verify::Thresholds;

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
    /// The most actions that run before the screen is checked, when a decision model is wired
    /// in (`Agent::with_decider`). 0 turns the checks off.
    pub chunk_actions: usize,
    /// What a checked screen must show for the plan to go on, and when to wait for the page
    /// instead.
    pub checkpoint: Thresholds,
    /// How long one wait for a loading page is.
    pub load_wait: Duration,
    /// The longest a look waits for the reviews of the last plan's zones that are still running;
    /// what has not come back by then is picked up at the look after.
    pub review_wait: Duration,
    /// How many of the newest turns keep their screenshots in the history.
    pub keep_images: usize,
    /// How many of the newest turns stay in full when the history is compacted.
    pub keep_turns: usize,
    /// The token budget the history is compacted to stay under.
    pub history_tokens: usize,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            max_actions: 30,
            unchecked_actions: 6,
            max_stale: 6,
            max_failed_steps: 3,
            chunk_actions: 6,
            checkpoint: Thresholds::default(),
            load_wait: Duration::from_secs(1),
            review_wait: Duration::from_secs(6),
            keep_images: 0,
            keep_turns: 8,
            history_tokens: 30_000,
        }
    }
}

impl Config {
    /// The most actions one reply may plan: `max_actions` when the screen is checked between
    /// batches, else no more than go out without a check.
    pub fn plan_limit(&self, checks: bool) -> usize {
        if checks { self.max_actions } else { self.max_actions.min(self.unchecked_actions) }
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
    /// With `survey`, where the fields still to fill lie on the page (screenshot pixels from its
    /// top): the survey adds a screen centred on one that none of its screens shows clear of the
    /// window's edges.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub survey_focus: Vec<f64>,
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
    pub(crate) config: Config,
    model: Box<dyn Model + Send + Sync>,
    /// The decision model that checks the screen between batches of a plan and reviews what the
    /// plan filled in; `None` turns both off. Shared with the threads the reviews run on.
    pub(crate) decider: Option<Arc<dyn Decider + Send + Sync>>,
    gate: Gate,
    sessions: Mutex<HashMap<String, Arc<Mutex<Session>>>>,
}

impl Agent {
    pub fn new(config: Config, model: Box<dyn Model + Send + Sync>) -> Self {
        Agent { config, model, decider: None, gate: Gate, sessions: Mutex::new(HashMap::new()) }
    }

    /// Wires in the decision model that checks the screen after each batch of a plan, so the
    /// next batch can go out without the driving model looking again.
    pub fn with_decider(mut self, decider: Box<dyn Decider + Send + Sync>) -> Self {
        self.decider = Some(Arc::from(decider));
        self
    }

    /// The live session with this id.
    pub(crate) fn session(&self, id: &str) -> Option<Arc<Mutex<Session>>> {
        self.sessions.lock().unwrap().get(id).cloned()
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
        let session = self.session(id).ok_or(StepError::NoSession)?;
        session.lock().unwrap().extend();
        Ok(())
    }

    /// Answers one look with the next actions.
    pub fn step(&self, id: &str, obs: Observation) -> Result<Step, StepError> {
        let session = self.session(id).ok_or(StepError::NoSession)?;
        let mut s = session.lock().unwrap();
        let url = obs.url.clone();
        let mut step = self.step_locked(&mut s, obs)?;
        // Every answer that asks for a survey says where the fields still to fill lie, however
        // it was made (the model, a check).
        if step.survey {
            step.survey_focus = s.survey_focus(&url);
        }
        Ok(step)
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
        s.viewport = obs.viewport;
        // The photos of the zones the plan just filled are reviewed on the side, and the reviews
        // that ended are taken in: what they found wrong is told to the model.
        for shot in review::accept_zone_shots(&obs) {
            self.start_review(s, shot);
        }
        self.collect_reviews(s);
        // A click that reached no control: the model is told where it clicked and how to aim, and
        // the field goes to the survey that follows.
        let unreached = focus::unreached_notes(&obs.results, &s.by_id);
        s.notes.extend(unreached);
        s.note_unreached_fields(&obs.results);
        // What happened to every action sent since the model last looked, which may be several
        // batches of one plan.
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
        // The model's plan may go on without it: when the checker confirms the screen after a
        // batch, the next batch goes out here and the model is not asked.
        if let Some(step) = self.continue_plan(s, &obs, &results, &sig, stale) {
            return Ok(step);
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
        // Whether the checker is wired in at all. The prompt and the schema follow this for the
        // whole run, so a check that fails along the way does not change the cached prompt.
        let checks = self.checks_available();

        let mut notes = s.notes.clone();
        if s.parts > 1 && s.sent == s.planned && s.notes.is_empty() {
            notes.push(format!("Your plan ran in {} parts. After each part but the last, a checker confirmed the screen showed what you expected.", s.parts));
        }
        let text = prompt::observation_text(number, s.step_limit, &obs, &results, &notes, &s.memo, stale);
        let images = if obs.survey.is_empty() {
            vec![obs.screenshot.clone()]
        } else {
            obs.survey.iter().map(|screen| screen.screenshot.clone()).collect()
        };
        let system = prompt::system_prompt(&s.task, &s.profile, &self.config, checks);
        // Fold the oldest turns before building the prompt when the history passes budget.
        s.memory.compact_if_over(self.config.keep_turns, self.config.history_tokens, system.len() / 4);
        let schema = model::reply_schema(s.task.survey, checks);
        // The prompt may still be too long for the model; one overflow folds the history to its
        // most recent turn and the step is tried once more.
        let mut compacted_for_overflow = false;
        let answer = loop {
            let mut messages = vec![Message { role: Role::System, text: system.clone(), cache: true, ..Default::default() }];
            messages.extend(s.memory.history(self.config.keep_images));
            // The prompt grows only at its end, so the provider caches up to the end of the history.
            if let Some(last) = messages.last_mut() {
                last.cache = true;
            }
            messages.push(Message { role: Role::User, text: text.clone(), images: images.clone(), cache: false });
            match recover::ask(self.model.as_ref(), messages, REPLY_SCHEMA_NAME, schema.clone()) {
                Ok(answer) => break answer,
                Err(recover::AskError::Model(err)) if err.kind == ErrorKind::ContextWindow && !compacted_for_overflow && !s.memory.is_empty() => {
                    compacted_for_overflow = true;
                    s.memory.fold_to(1);
                    continue;
                }
                Err(recover::AskError::Model(err)) => return Err(StepError::Model(err)),
                Err(recover::AskError::Reply { why, usage }) => {
                    s.usage.add(usage);
                    return Err(StepError::Reply(why));
                }
            }
        };
        s.usage.add(answer.usage);
        let mut reply = answer.reply;

        // Only a step the model answered counts: a retry of a failed call sends the same screen.
        s.step = number;
        s.stale = stale;
        s.last_signature = Some(sig);
        s.failed_streak = streak;
        s.last_failure = failure;
        s.carried.clear();
        s.notes.clear();
        if let Some(memo) = reply.memo.take() {
            s.memo = model::clip_text(memo.trim(), model::MAX_MEMO_CHARS);
        }
        s.message = reply.message.trim().to_string();

        let screens: Vec<f64> = obs.survey.iter().map(|screen| screen.scroll_y).collect();
        let (planned, mut dropped) = model::check_actions(number, std::mem::take(&mut reply.actions), &obs.viewport, self.config.plan_limit(checks), &screens);
        let (mut planned, survey_asked) = without_survey(planned);
        // A run that did not turn surveys on is not told they exist; one the model asks for anyway is ignored.
        let survey_asked = survey_asked && s.task.survey;
        action::inherit_zones(&mut planned);
        // Each labelled point of a plan made from a survey is checked against its label before
        // the plan runs; a doubt is told to the model, never acted on.
        if reply.status == Status::Working {
            self.check_plan_points(s, &planned, &obs);
        }
        self.gate.apply(s, &obs, &mut reply, &mut planned, &mut dropped);
        // What this plan fills in, by zone, for the reviews of its zones.
        s.plan_gen += 1;
        s.expect = review::expectations_of(&planned, &obs);
        s.expect_url = observe::without_fragment(&obs.url).to_string();
        s.plan_scroll_y = obs.viewport.scroll_y;
        // The line that stands for the step once it is folded names the whole plan, not only
        // the batch that goes out first.
        let summary = memory::summary_line(number, &s.message, &planned);

        let (actions, dropped) = if reply.status != Status::Working {
            // A run that ends may still scroll what the person must act on into view.
            s.forget_plan();
            (scroll_only(planned, MAX_STOP_SCROLLS), dropped)
        } else {
            if planned.is_empty() && !survey_asked {
                // A working run with nothing valid to do waits and looks again.
                dropped.push("no usable action; waiting before the next look".to_string());
                planned.push(Action::new(format!("s{number}a1"), Kind::Wait { ms: 1000 }));
            }
            self.take_plan(s, planned, dropped)
        };

        s.memory.record(Turn { number, text, images, answer: answer.content, summary });
        s.memory.release_images(self.config.keep_images);

        let survey = reply.status == Status::Working && self.survey_next(s, survey_asked);
        let step = Step {
            status: reply.status,
            message: s.message.clone(),
            stop: if reply.status == Status::Working { None } else { reply.stop.clone() },
            actions,
            number,
            usage: s.usage,
            dropped,
            survey,
            survey_focus: Vec::new(),
        };
        if step.status != Status::Working {
            s.finished = true;
        }
        Ok(step)
    }
}

impl Agent {
    /// Whether the browser's next look is a survey of the whole page: when the model asked for
    /// one, or something found on the way needs the whole page looked at again. Never for a run
    /// without surveys.
    pub(crate) fn survey_next(&self, s: &mut Session, asked: bool) -> bool {
        if (asked || s.survey_again) && s.task.survey {
            s.survey_again = false;
            return true;
        }
        false
    }
}

/// The most scroll actions a step that ends the run may still carry, to bring what the person
/// must act on into view.
const MAX_STOP_SCROLLS: usize = 2;

/// Takes the survey requests out of a plan and says whether there was one.
fn without_survey(actions: Vec<Action>) -> (Vec<Action>, bool) {
    let mut asked = false;
    let kept = actions
        .into_iter()
        .filter(|action| {
            let is_survey = matches!(action.kind, Kind::Survey);
            asked |= is_survey;
            !is_survey
        })
        .collect();
    (kept, asked)
}

/// The first `max` scrolls of a plan, and nothing else.
fn scroll_only(actions: Vec<Action>, max: usize) -> Vec<Action> {
    actions.into_iter().filter(|action| matches!(action.kind, Kind::Scroll { .. })).take(max).collect()
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
    Step { status, message, stop: Some(stop), number: s.step, usage: s.usage, ..Default::default() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::observe::Viewport;
    use crate::ports::{ModelRequest, ModelResponse};

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

    struct OverflowOnce {
        calls: std::sync::Mutex<u32>,
    }

    impl Model for OverflowOnce {
        fn complete(&self, _request: ModelRequest) -> Result<ModelResponse, Error> {
            let mut calls = self.calls.lock().unwrap();
            *calls += 1;
            if *calls == 2 {
                return Err(Error::new(ErrorKind::ContextWindow, "prompt too long"));
            }
            Ok(ModelResponse { content: r#"{"status":"working","message":"","actions":[{"kind":"wait","ms":100}]}"#.to_string(), ..Default::default() })
        }
        fn name(&self) -> &str {
            "overflow-once"
        }
    }

    #[test]
    fn a_context_overflow_folds_the_history_and_retries() {
        let agent = Agent::new(Config { max_stale: 100, ..Config::default() }, Box::new(OverflowOnce { calls: std::sync::Mutex::new(0) }));
        let id = agent.start(Task::new("go on"), Profile::default());
        // First step records a turn; second step overflows, folds, and succeeds on retry.
        assert_eq!(agent.step(&id, look()).unwrap().status, Status::Working);
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
