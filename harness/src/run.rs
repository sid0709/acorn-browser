//! The loop: one step from an observation to the next batch of actions, with the stall checks,
//! the gate slot, and the end of the run.

use std::collections::{BTreeMap, HashMap};
use std::fmt;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};

use crate::action::{self, Action, Kind};
use crate::change;
use crate::focus;
use crate::map::{self, SettledMap};
use crate::mark;
use crate::memory::{self, Turn};
use crate::model::{self, REPLY_SCHEMA_NAME};
use crate::prompt;
use crate::recover;
use crate::review;
use crate::observe::{self, ActionResult, Observation};
use crate::ports::{Browser, Decider, Error, ErrorKind, Message, Model, Role, Usage};
use crate::profile::Profile;
use crate::report::Report;
use crate::session::Session;
use crate::task::{Allowance, Irreversible, StopReason, Task};
use crate::todo::FieldState;
use crate::trace::{self, ModelCall, SessionTrace, StartTrace, StepTrace, Tracer};
use crate::verify::Thresholds;

/// The knobs of the loop.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
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
    /// How many times a "done" the screen does not confirm is sent back to the model before the
    /// run is reported as one that could not confirm; negative accepts every "done".
    pub done_passes: i32,
    /// How sure the checker must be that the screen shows the task done (a probability).
    pub done_confirm: f64,
    /// How many times a stop for the person is sent back, to finish everything that does not
    /// need them first; 0 accepts every stop at once.
    pub stop_passes: u32,
    /// How sure the decision model must be that a field the model read as empty is one only the
    /// person can fill (a probability) for a stop to stand with it empty.
    pub person_field: f64,
    /// How sure the decision model must be that a check the person must pass by hand is on
    /// screen for a stop with reason captcha to stand; below it the stop is sent back once, to
    /// press the button that sends the page first. 0 takes the model's word.
    pub captcha_confirm: f64,
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
            done_passes: 2,
            done_confirm: 0.7,
            stop_passes: 2,
            person_field: 0.5,
            captcha_confirm: 0.7,
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

/// A question for the person, which the run goes on without an answer to: the model chose the
/// most likely answer meanwhile. An answer, when one comes (`Agent::answer`), reaches the model
/// as a message, and it redoes what the answer changes.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Question {
    /// Given by the harness, as `q<n>`.
    pub id: String,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answer: Option<String>,
    /// Set when the question asks leave for an action that cannot be taken back: a yes or no
    /// answer sets what the run may do (`Agent::allow`, `Agent::forbid`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub allows: Option<Irreversible>,
}

/// The harness's answer to one look: what to do next, and how the run stands.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Step {
    pub status: Status,
    /// One line for the person.
    pub message: String,
    /// With a status that ends the run: the answer to what the task asks, in words read from
    /// the page, or what was found so far when the run stops short.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answer: Option<String>,
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
    /// The run's to-do list of the page, when it changed: each field as the model read it on its
    /// last survey and the reviews corrected it.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fields: Vec<FieldState>,
    /// The parts of the page the model settled, when they changed: the browser paints them on
    /// the map the person sees and does not photograph them again in the next survey. An empty
    /// map says nothing is settled any more.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub settled: Option<SettledMap>,
    /// The questions asked of the person this step. The run goes on; an answer comes back
    /// through `Agent::answer`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub questions: Vec<Question>,
    /// With a status that ends the run: the whole picture for the person.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub report: Option<Report>,
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
    /// Writes every step to disk, when a trace folder is set (`with_trace_dir`).
    pub(crate) trace: Option<Tracer>,
    sessions: Mutex<HashMap<String, Arc<Mutex<Session>>>>,
}

impl Agent {
    pub fn new(config: Config, model: Box<dyn Model + Send + Sync>) -> Self {
        Agent { config, model, decider: None, trace: None, sessions: Mutex::new(HashMap::new()) }
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
    pub fn start(&self, mut task: Task, profile: Profile) -> String {
        // DOM mode plans from the map, never from screens of a survey.
        if task.dom_mode() {
            task.survey = false;
        }
        let session = Session::new(task, profile);
        let id = session.id.clone();
        if let Some(tracer) = &self.trace {
            let system = prompt::system_prompt(&session.task, &session.profile, &self.config, self.checks_available());
            let info = SessionTrace {
                started: trace::rfc3339(session.created),
                start: StartTrace {
                    url: session.task.start_url.as_deref().unwrap_or(""),
                    goal: &session.task.goal,
                    survey: session.task.survey,
                    mode: session.task.mode,
                    max_steps: session.task.persistence.max_steps,
                },
                model: self.model.name(),
                screen_model: self.decider.as_ref().map(|d| d.name().to_string()).unwrap_or_default(),
                config: &self.config,
            };
            // A trace that cannot be written never stops a run.
            let _ = tracer.record_session(&id, &system, &info);
        }
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
    /// usual; the person may have done part of the page by hand in between, and the model is
    /// told so.
    pub fn resume(&self, id: &str) -> Result<(), StepError> {
        let session = self.session(id).ok_or(StepError::NoSession)?;
        let mut s = session.lock().unwrap();
        s.touch();
        let note = if s.finished {
            format!(
                "You stopped the run ({}). The person has let it go on, so they may have changed the page since. Look at the screen as it is now and carry on from your notes; do not redo what they say is done.",
                model::clip_text(&s.stopped_for, memory::MAX_SUMMARY_CHARS)
            )
        } else {
            "The run was paused and the person let it go on. The actions you last planned may not have run. Judge by the screenshot, not by your memory of the plan.".to_string()
        };
        s.notes.push(note);
        s.forget_plan();
        s.extend();
        Ok(())
    }

    /// Takes a message the person wrote while the run goes on. The model reads it with its next
    /// look, and a plan running without the model stops for it, so the model can change course.
    pub fn say(&self, id: &str, text: &str) -> Result<(), StepError> {
        let session = self.session(id).ok_or(StepError::NoSession)?;
        let mut s = session.lock().unwrap();
        s.touch();
        let text = text.trim();
        if !text.is_empty() {
            s.inbox.push(model::clip_text(text, MAX_MESSAGE_CHARS));
        }
        Ok(())
    }

    /// Takes the person's answer to a question the run asked (`Step::questions`). It reaches the
    /// model as a message, naming the question, so it redoes what the answer changes. An answer
    /// to a question the run did not ask is a plain message.
    pub fn answer(&self, id: &str, question_id: &str, text: &str) -> Result<(), StepError> {
        let session = self.session(id).ok_or(StepError::NoSession)?;
        let mut s = session.lock().unwrap();
        s.touch();
        let text = model::clip_text(text.trim(), MAX_MESSAGE_CHARS);
        if text.is_empty() {
            return Ok(());
        }
        let message = match s.questions.iter_mut().find(|q| q.id == question_id) {
            Some(question) => {
                question.answer = Some(text.clone());
                // A plain yes or no to a question that asked leave settles what the run may do.
                if let Some(kind) = question.allows {
                    match text.trim_end_matches(['.', '!']).to_lowercase().as_str() {
                        "yes" | "y" => return Ok(s.allow(kind, Allowance::Auto)),
                        "no" | "n" => return Ok(s.allow(kind, Allowance::Never)),
                        _ => {}
                    }
                }
                format!("Answer to your question {:?}: {text}", question.text)
            }
            None => text,
        };
        s.inbox.push(message);
        Ok(())
    }

    /// Lets the run do one kind of action that cannot be taken back on its own, from now on, and
    /// tells the model so.
    pub fn allow(&self, id: &str, kind: Irreversible) -> Result<(), StepError> {
        let session = self.session(id).ok_or(StepError::NoSession)?;
        let mut s = session.lock().unwrap();
        s.touch();
        s.allow(kind, Allowance::Auto);
        Ok(())
    }

    /// Keeps the run from one kind of action that cannot be taken back: the person does it
    /// themselves, and the run ends ready for them when nothing else is left.
    pub fn forbid(&self, id: &str, kind: Irreversible) -> Result<(), StepError> {
        let session = self.session(id).ok_or(StepError::NoSession)?;
        let mut s = session.lock().unwrap();
        s.touch();
        s.allow(kind, Allowance::Never);
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
        step.fields = s.take_fields();
        // Every answer carries the settled parts when they changed, however it was made.
        step.settled = s.take_settled_map();
        if step.status != Status::Working {
            s.last_status = step.status;
            s.last_stop = step.stop.clone();
            step.report = Some(s.report(step.status, step.stop.clone()));
        }
        Ok(step)
    }

    fn step_locked(&self, s: &mut Session, obs: Observation) -> Result<Step, StepError> {
        s.touch();
        if s.finished {
            return Err(StepError::SessionOver);
        }
        s.seq += 1;
        s.step_started = SystemTime::now();
        if !obs.viewport.has_size() {
            return Err(self.refuse(s, &obs, "the viewport has no size".to_string()));
        }
        let (sig, width, height) = match change::signature(&obs.screenshot) {
            Ok(read) => read,
            // A look the browser could not photograph still carries the page in DOM mode: the
            // map stands in for the picture, for telling a page that did not change.
            Err(_) if obs.screenshot.is_empty() && s.task.dom_mode() && obs.page.is_some() => {
                (change::text_signature(&obs.page.as_ref().map(|page| page.text(&obs.viewport)).unwrap_or_default()), obs.viewport.width, obs.viewport.height)
            }
            Err(why) => return Err(self.refuse(s, &obs, why)),
        };
        // The model measures coordinates in the image it is shown. If the image is not the size
        // the viewport says, every point it gives would land somewhere else on the page.
        if width.abs_diff(obs.viewport.width) > change::SIZE_TOLERANCE || height.abs_diff(obs.viewport.height) > change::SIZE_TOLERANCE {
            let why = format!("the screenshot is {width}x{height} pixels but the viewport says {}x{}", obs.viewport.width, obs.viewport.height);
            return Err(self.refuse(s, &obs, why));
        }
        s.viewport = obs.viewport;
        s.see_page(&obs.url);
        s.cover.see(&obs.url, &obs.viewport);
        s.forget_settled_if_stale(&obs);
        s.check_settled(obs.viewport.scroll_y, obs.viewport.height, &sig);
        s.see_survey(&obs);
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
        // batches of one plan. Whether the click that sends the page went through, and whether
        // the page then refused it, is read before anything else is decided.
        let results: Vec<ActionResult> = s.carried.iter().cloned().chain(obs.results.iter().cloned()).collect();
        s.note_commit_results(&obs.results);
        self.note_refused_send(s, &obs);
        if s.at_step_limit() {
            return Ok(self.end_run(
                s,
                &obs,
                0,
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
        // the same screen again is expected, not a stall; so is the page after actions that
        // only read it.
        let mut stale = 0;
        if s.step > 0 && obs.survey.is_empty() && !s.last_plan_read_only && change::unchanged(&sig, s.last_signature.as_deref().unwrap_or(&[])) {
            stale = s.stale + 1;
        }
        if stale >= self.config.max_stale {
            return Ok(self.end_run(
                s,
                &obs,
                stale,
                Status::Stuck,
                format!("The page did not change for {stale} steps in a row."),
                StopInfo {
                    reason: StopReason::NoChange,
                    problem: "The page stopped responding to the run's clicks and typing.".to_string(),
                    action: "Check the page for anything in the way, then let the run go on.".to_string(),
                },
            ));
        }
        // The person wrote: a plan running without the model stops here, so the model can change
        // course with their words in front of it.
        if !s.inbox.is_empty() && !s.verify.is_empty() {
            self.abandon(s, "The person wrote to you meanwhile, so the rest of your plan did not run; read their message below.");
        }
        // The model's plan may go on without it: when the checker confirms the screen after a
        // batch, the next batch goes out here and the model is not asked.
        if let Some(step) = self.continue_plan(s, &obs, &results, &sig, stale) {
            let mut entry = entry_for(s, &obs, stale);
            entry.step = s.step;
            entry.source = trace::SOURCE_CHECK.to_string();
            entry.check = s.last_check.take();
            entry.status = step.status;
            entry.message = step.message.clone();
            entry.dropped = step.dropped.clone();
            entry.usage = s.usage;
            self.record(s, entry, &obs.screenshot, &obs.survey, obs.page.as_ref(), &step.actions, Vec::new());
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
            return Ok(self.end_run(
                s,
                &obs,
                stale,
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
        let reach = s.cover.line(&obs.viewport);
        if !reach.is_empty() {
            notes.push(reach);
        }
        if !obs.survey.is_empty() {
            for note in [s.settled_note(), s.fields_note(&obs)] {
                if !note.is_empty() {
                    notes.push(note);
                }
            }
        }
        // In DOM mode the model reads the page map and no picture; a page the browser could not
        // map is one this mode cannot read, and the run says so rather than guessing.
        let dom = s.task.dom_mode();
        let map = if dom { obs.page.as_ref().map(|page| page.text(&obs.viewport)) } else { None };
        if dom && obs.page.as_ref().is_none_or(|page| page.nodes.is_empty()) {
            return Ok(self.end_run(
                s,
                &obs,
                stale,
                Status::Stuck,
                "The page could not be read in DOM mode: the browser sent no page map for it.".to_string(),
                StopInfo {
                    reason: StopReason::PageProblem,
                    problem: "This page cannot be read in DOM mode.".to_string(),
                    action: "Run the task in image mode, or do this page yourself and let the run go on.".to_string(),
                },
            ));
        }
        let text = prompt::observation_text(number, s.step_limit, &obs, &results, &notes, &s.inbox, &s.memo, stale, map.as_deref());
        // A survey's screens go to the model with their numbers written on them; DOM mode sends none.
        let images = if dom {
            Vec::new()
        } else if obs.survey.is_empty() {
            vec![obs.screenshot.clone()]
        } else {
            mark::badged_images(&obs)
        };
        let system = prompt::system_prompt(&s.task, &s.profile, &self.config, checks);
        // Fold the oldest turns before building the prompt when the history passes budget.
        s.memory.compact_if_over(self.config.keep_turns, self.config.history_tokens, system.len() / 4);
        let schema = model::reply_schema(s.task.survey, checks, dom);
        // The prompt may still be too long for the model; one overflow folds the history to its
        // most recent turn and the step is tried once more.
        let mut compacted_for_overflow = false;
        let mut calls: Vec<ModelCall> = Vec::new();
        let answer = loop {
            let mut messages = vec![Message { role: Role::System, text: system.clone(), cache: true, ..Default::default() }];
            messages.extend(s.memory.history(self.config.keep_images));
            // The prompt grows only at its end, so the provider caches up to the end of the history.
            if let Some(last) = messages.last_mut() {
                last.cache = true;
            }
            messages.push(Message { role: Role::User, text: text.clone(), images: images.clone(), cache: false });
            let history_tokens = s.memory.budget_used(system.len() / 4);
            let driving = |made: &[recover::Call]| made.iter().map(|call| ModelCall::driving(call, history_tokens, self.config.history_tokens)).collect::<Vec<_>>();
            match recover::ask(self.model.as_ref(), messages, REPLY_SCHEMA_NAME, schema.clone()) {
                Ok(answer) => {
                    calls.extend(driving(&answer.calls));
                    break answer;
                }
                Err(recover::AskError::Model { error, calls: made }) if error.kind == ErrorKind::ContextWindow && !compacted_for_overflow && !s.memory.is_empty() => {
                    calls.extend(driving(&made));
                    compacted_for_overflow = true;
                    s.memory.fold_to(1);
                    continue;
                }
                Err(recover::AskError::Model { error, calls: made }) => {
                    calls.extend(driving(&made));
                    self.fail(s, &obs, stale, error.to_string(), calls);
                    return Err(StepError::Model(error));
                }
                Err(recover::AskError::Reply { why, usage, calls: made }) => {
                    s.usage.add(usage);
                    calls.extend(driving(&made));
                    self.fail(s, &obs, stale, why.clone(), calls);
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
        s.inbox.clear();
        if let Some(memo) = reply.memo.take() {
            s.memo = model::clip_text(memo.trim(), model::MAX_MEMO_CHARS);
        }
        s.note_fields(&reply, &obs);
        if let Some(assumed) = &reply.assumed {
            s.note_assumed(assumed);
        }
        // A question for the person is kept, and sent with the step; the run goes on. One the
        // run already asked, in the same words, is not asked again.
        let questions: Vec<Question> = reply
            .question
            .as_deref()
            .map(str::trim)
            .filter(|text| !text.is_empty() && !s.questions.iter().any(|asked| asked.text == *text))
            .map(|text| Question { id: format!("q{}", s.questions.len() + 1), text: model::clip_text(text, MAX_MESSAGE_CHARS), answer: None, allows: None })
            .into_iter()
            .collect();
        s.questions.extend(questions.iter().cloned());

        let screens: Vec<f64> = obs.survey.iter().map(|screen| screen.scroll_y).collect();
        let written = reply.actions.len();
        let (planned, mut dropped) = model::check_actions(number, std::mem::take(&mut reply.actions), &obs.viewport, self.config.plan_limit(checks), &screens, obs.page.as_ref());
        // How many actions of the plan could not be carried out: the click that sends the page
        // waits for them.
        // A survey or a resume is a request the harness grants, not an action lost.
        let mut lost = written.saturating_sub(planned.len());
        let (mut planned, survey_asked) = without_survey(planned);
        // A plan kept at an unsure check goes on where it stopped when the model says resume.
        let (kept, resume) = without_resume(planned);
        planned = kept;
        let resume = resume && reply.status == Status::Working && planned.is_empty() && !s.plan.is_empty();
        if !resume {
            s.plan.clear();
        }
        // A run that did not turn surveys on is not told they exist; one the model asks for anyway is ignored.
        let survey_asked = survey_asked && s.task.survey;
        action::inherit_zones(&mut planned);
        let (kept, blue) = s.without_blue_scrolls(planned, &obs);
        planned = kept;
        if blue > 0 {
            lost += blue;
            dropped.push(format!("{} to a settled part of the page not made", prompt::count(blue, "scroll")));
            s.notes.push(map::BLUE_SCROLL_NOTE.to_string());
        }
        // Each labelled point of a plan made from a survey is checked against its label before
        // the plan runs; a doubt is told to the model, never acted on.
        if reply.status == Status::Working {
            self.check_plan_points(s, &planned, &obs);
        }
        // The gate: the one place the harness may stop, change, or question the plan.
        self.gate(s, &obs, &mut reply, &mut planned, &mut dropped, number, lost);
        s.message = reply.message.trim().to_string();
        s.note_commit_planned(&planned, &obs);
        // What this plan fills in, by zone, for the reviews of its zones.
        s.plan_gen += 1;
        s.expect = BTreeMap::new();
        s.expect_url = observe::without_fragment(&obs.url).to_string();
        s.plan_scroll_y = obs.viewport.scroll_y;
        if let Some(settled) = &reply.settled {
            s.mark_settled(&obs, settled, &planned);
        }
        s.set_fence(&planned, &obs);
        // The line that stands for the step once it is folded names the whole plan, not only
        // the batch that goes out first.
        let summary = memory::summary_line(number, &s.message, &planned);

        let (actions, mut dropped) = if reply.status != Status::Working {
            // A run that ends may still scroll what the person must act on into view.
            s.forget_plan();
            (scroll_only(planned, MAX_STOP_SCROLLS), dropped)
        } else if resume {
            let plan = std::mem::take(&mut s.plan);
            self.send_batch(s, plan, dropped)
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

        // The gate may have asked the person for leave: that question goes with the step too.
        let mut questions = questions;
        questions.extend(s.asked_now.drain(..));
        // What the harness held back since the model last looked, so the trace shows it.
        let mut withheld = std::mem::take(&mut s.withheld);
        withheld.append(&mut dropped);
        let dropped = withheld;
        let survey = reply.status == Status::Working && self.survey_next(s, survey_asked);
        s.last_plan_read_only = !actions.is_empty() && actions.iter().all(|a| matches!(a.kind, Kind::Read));
        let step = Step {
            status: reply.status,
            message: s.message.clone(),
            answer: if reply.status == Status::Working { None } else { reply.answer.as_deref().map(str::trim).filter(|a| !a.is_empty()).map(str::to_string) },
            stop: if reply.status == Status::Working { None } else { reply.stop.clone() },
            actions,
            number,
            usage: s.usage,
            dropped,
            survey,
            survey_focus: Vec::new(),
            fields: Vec::new(),
            settled: None,
            questions,
            report: None,
        };
        if step.status != Status::Working {
            s.finished = true;
            s.stopped_for = step.message.clone();
        }
        let mut entry = entry_for(s, &obs, stale);
        entry.step = number;
        entry.observation = reply.observation.clone();
        entry.memo = s.memo.clone();
        entry.status = step.status;
        entry.message = step.message.clone();
        entry.answer = step.answer.clone();
        entry.stop = step.stop.clone();
        entry.dropped = step.dropped.clone();
        entry.check = s.last_check.take();
        entry.usage = s.usage;
        self.record(s, entry, &obs.screenshot, &obs.survey, obs.page.as_ref(), &step.actions, calls);
        Ok(step)
    }

    /// Refuses a look the harness cannot read, and says so in the trace.
    fn refuse(&self, s: &mut Session, obs: &Observation, why: String) -> StepError {
        let mut entry = entry_for(s, obs, 0);
        entry.error = format!("bad observation: {why}");
        self.record(s, entry, &obs.screenshot, &[], obs.page.as_ref(), &[], Vec::new());
        StepError::BadObservation(why)
    }

    /// Records a step the model did not answer: the calls made and why it failed.
    fn fail(&self, s: &mut Session, obs: &Observation, stale: u32, error: String, calls: Vec<ModelCall>) {
        let mut entry = entry_for(s, obs, stale);
        entry.error = error;
        entry.usage = s.usage;
        self.record(s, entry, &obs.screenshot, &obs.survey, obs.page.as_ref(), &[], calls);
    }

    /// Ends the run with no actions: the person is told why and what they can do, and the trace
    /// why the harness gave up.
    fn end_run(&self, s: &mut Session, obs: &Observation, stale: u32, status: Status, message: String, stop: StopInfo) -> Step {
        s.finished = true;
        s.stopped_for = message.clone();
        let mut entry = entry_for(s, obs, stale);
        entry.status = status;
        entry.message = message.clone();
        entry.stop = Some(stop.clone());
        self.record(s, entry, &obs.screenshot, &obs.survey, obs.page.as_ref(), &[], Vec::new());
        Step { status, message, stop: Some(stop), number: s.step, usage: s.usage, ..Default::default() }
    }
}

/// The entry of the trace for a look, before the step fills in what it decided.
fn entry_for(s: &Session, obs: &Observation, stale: u32) -> StepTrace {
    StepTrace {
        seq: s.seq,
        step: s.step + 1,
        mode: s.task.mode,
        at: trace::rfc3339(SystemTime::now()),
        url: obs.url.clone(),
        title: obs.title.clone(),
        viewport: obs.viewport,
        focus: obs.focus.clone(),
        notes: obs.notes.clone(),
        results: obs.results.clone(),
        stale,
        survey_screens: obs.survey.len(),
        memo: s.memo.clone(),
        usage: s.usage,
        ..Default::default()
    }
}

/// The most characters one message from the person keeps.
pub const MAX_MESSAGE_CHARS: usize = 4000;

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

/// Takes the resume requests out of a plan and says whether there was one.
fn without_resume(actions: Vec<Action>) -> (Vec<Action>, bool) {
    let mut asked = false;
    let kept = actions
        .into_iter()
        .filter(|action| {
            let is_resume = matches!(action.kind, Kind::Resume);
            asked |= is_resume;
            !is_resume
        })
        .collect();
    (kept, asked)
}

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

    /// A run read the options of a form one by one, six `read` actions in a row, and the stale
    /// count ended it as a page that stopped responding: a read leaves the page as it was.
    #[test]
    fn actions_that_only_read_the_page_do_not_count_as_a_page_that_never_changes() {
        use crate::page::{PageMap, PageNode};
        let reply = r#"{"status":"working","message":"Reading.","actions":[{"kind":"read","target":2}]}"#;
        let agent = Agent::new(Config { max_stale: 2, ..Config::default() }, Box::new(Fixed(reply)));
        let mut task = Task::new("read the options");
        task.mode = crate::task::Mode::Dom;
        let id = agent.start(task, Profile::default());
        let page = PageMap {
            nodes: vec![
                PageNode { id: 1, role: "button".into(), name: "Go".into(), x: 10.0, y: 10.0, w: 20.0, h: 10.0, ..Default::default() },
                PageNode { id: 2, role: "text".into(), name: "A paragraph cut short…".into(), y: 30.0, w: 50.0, h: 10.0, ..Default::default() },
            ],
        };
        for _ in 0..4 {
            let mut obs = look();
            obs.page = Some(page.clone());
            let step = agent.step(&id, obs).unwrap();
            assert_eq!(step.status, Status::Working);
            assert!(matches!(step.actions[0].kind, Kind::Read), "{:?}", step.actions);
        }
    }

    /// The browser could not photograph a page mid-navigation and the run ended with an error:
    /// in DOM mode the map carries the look, so it goes on; in image mode nothing does.
    #[test]
    fn a_look_without_a_picture_goes_on_in_dom_mode_and_is_refused_in_image_mode() {
        use crate::page::{PageMap, PageNode};
        let reply = r#"{"status":"working","message":"","actions":[{"kind":"wait","ms":100}]}"#;
        let agent = Agent::new(Config::default(), Box::new(Fixed(reply)));
        let mut task = Task::new("wait");
        task.mode = crate::task::Mode::Dom;
        let id = agent.start(task, Profile::default());
        let mut obs = look();
        obs.screenshot = String::new();
        obs.page = Some(PageMap { nodes: vec![PageNode { id: 1, role: "button".into(), name: "Go".into(), x: 10.0, y: 10.0, w: 20.0, h: 10.0, ..Default::default() }] });
        assert_eq!(agent.step(&id, obs).unwrap().status, Status::Working);
        let agent = Agent::new(Config::default(), Box::new(Fixed(reply)));
        let id = agent.start(Task::new("wait"), Profile::default());
        let mut obs = look();
        obs.screenshot = String::new();
        assert!(matches!(agent.step(&id, obs), Err(StepError::BadObservation(_))));
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
    fn a_question_is_sent_with_the_step_and_its_answer_reaches_the_model() {
        let reply = r#"{"status":"working","message":"","question":"Which card should I use, the blue one or the red one?","actions":[{"kind":"wait","ms":100}]}"#;
        let (model, seen) = crate::testing::Replying::new(reply);
        let agent = Agent::new(Config { max_stale: 100, ..Config::default() }, model);
        let id = agent.start(Task::new("buy a kettle"), Profile::default());
        let step = agent.step(&id, look()).unwrap();
        assert_eq!(step.questions, vec![Question { id: "q1".into(), text: "Which card should I use, the blue one or the red one?".into(), answer: None, allows: None }]);
        agent.answer(&id, "q1", "the blue one").unwrap();
        agent.answer(&id, "q9", "and no gift wrap").unwrap();
        assert!(agent.step(&id, look()).unwrap().questions.is_empty());
        let seen = seen.lock().unwrap();
        assert!(seen[1].contains("- Answer to your question \"Which card should I use, the blue one or the red one?\": the blue one\n- and no gift wrap\n"), "{}", seen[1]);
    }

    #[test]
    fn dom_mode_sends_the_map_and_no_picture_and_cannot_go_on_without_a_map() {
        use crate::page::{PageMap, PageNode};
        use crate::ports::ModelRequest;
        struct Seeing(std::sync::Mutex<Vec<(usize, String, String)>>);
        impl Model for Seeing {
            fn complete(&self, request: ModelRequest) -> Result<ModelResponse, Error> {
                let last = request.messages.last().unwrap();
                self.0.lock().unwrap().push((last.images.len(), last.text.clone(), request.messages[0].text.clone()));
                Ok(ModelResponse { content: r#"{"status":"working","message":"","actions":[{"kind":"click","target":1,"label":"Go","commit":null,"modifiers":null,"check":"url~=\"/next\""}]}"#.to_string(), ..Default::default() })
            }
            fn name(&self) -> &str {
                "seeing"
            }
        }
        let seen = std::sync::Arc::new(Seeing(std::sync::Mutex::new(Vec::new())));
        struct Shared(std::sync::Arc<Seeing>);
        impl Model for Shared {
            fn complete(&self, request: ModelRequest) -> Result<ModelResponse, Error> {
                self.0.complete(request)
            }
            fn name(&self) -> &str {
                "seeing"
            }
        }
        let agent = Agent::new(Config::default(), Box::new(Shared(seen.clone())));
        let mut task = Task::new("go");
        task.mode = crate::task::Mode::Dom;
        let id = agent.start(task, Profile::default());
        let mut obs = look();
        obs.page = Some(PageMap { nodes: vec![PageNode { id: 1, role: "button".into(), name: "Go".into(), x: 10.0, y: 10.0, w: 20.0, h: 10.0, ..Default::default() }] });
        let step = agent.step(&id, obs).unwrap();
        assert_eq!(step.status, Status::Working);
        assert_eq!(step.actions[0].target.as_ref().map(|t| t.id), Some(1));
        let calls = seen.0.lock().unwrap();
        assert_eq!(calls[0].0, 0, "no image in DOM mode");
        assert!(calls[0].1.contains("The map of the page") && calls[0].1.contains("button[1] \"Go\""), "{}", calls[0].1);
        assert!(calls[0].2.contains("# The map"), "the DOM prompt");
        drop(calls);
        // A look with no map ends the run rather than guessing from nothing.
        let stuck = agent.step(&id, look()).unwrap();
        assert_eq!(stuck.status, Status::Stuck);
        assert_eq!(stuck.stop.unwrap().reason, StopReason::PageProblem);
    }

    #[test]
    fn a_done_reply_ends_the_run() {
        let reply = r#"{"status":"done","message":"Sent.","answer":"The form was sent."}"#;
        let agent = Agent::new(Config::default(), Box::new(Fixed(reply)));
        let id = agent.start(Task::new("send it"), Profile::default());
        assert_eq!(agent.step(&id, look()).unwrap().status, Status::Done);
        assert!(matches!(agent.step(&id, look()), Err(StepError::SessionOver)));
    }
}
