//! The flight recorder: per step, what the model saw, was told, and answered, and what it cost.
//!
//! A run is written to disk when a trace folder is set, so it can be debugged without guessing:
//! the screenshot the model was shown, the same screenshot with every action drawn on it, what
//! the model was sent and answered, what the harness made of the answer, and how it went (time,
//! tokens, cost, errors). A folder of these is also a recorded run to replay against a change to
//! the harness. Typed secrets are never written. The folder holds the person's pages, so it stays
//! on this machine. The files, their names and their fields are those acorn's `tracesum` reads,
//! so one tool sums a run of either.
//!
//! One folder per run, in the order the run's steps were asked (a retried step is its own
//! numbered entry, so a failure is never overwritten):
//!
//! ```text
//! session.json   the run's start: task, models, limits
//! system.txt     the standing prompt the model was given
//! NNN.jpg        the screenshot the model saw (NNN.surveyK.jpg for a survey's screens)
//! NNN.marked.jpg the same screenshot with each action's point drawn and numbered
//! NNN.page.txt   the page map the browser sent, as the model would read it in DOM mode
//! NNN.json       what the page reported, what the model decided, what was sent back
//! NNN.model.json every model call of the step: messages, raw answer, tokens, cost, time
//! timeline.txt   one line per entry, to read a run at a glance
//! ```

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::action::{Action, Commit, Kind};
use crate::change;
use crate::mark;
use crate::memory;
use crate::model;
use crate::observe::{ActionResult, Focus, SurveyScreen, Viewport};
use crate::page::PageMap;
use crate::ports::{Error, Role, Usage, Verdicts};
use crate::recover::Call;
use crate::run::{Agent, Config, Status, StopInfo};
use crate::session::Session;

/// Marks an entry the decision model answered, with no call to the driving model.
pub const SOURCE_CHECK: &str = "check";
/// The kind of a decision model's call, as the trace names it.
pub const KIND_DECISION: &str = "decision";
/// The most characters of an error, and of the message, one timeline line keeps.
const TIMELINE_ERROR_CHARS: usize = 160;
const TIMELINE_MESSAGE_CHARS: usize = 140;

/// Writes runs to a folder, one folder per run.
#[derive(Clone, Debug)]
pub struct Tracer {
    dir: PathBuf,
}

/// One entry of the run (`NNN.json`).
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StepTrace {
    pub seq: u32,
    pub step: u32,
    /// How the model saw the page on this step: `image` or `dom`.
    pub mode: crate::task::Mode,
    /// `check` when the decision model carried the plan on; empty when the driving model looked.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub source: String,
    #[serde(skip_serializing_if = "is_zero")]
    pub survey_screens: usize,
    /// How many nodes the page map had, and how many of them controls; 0 without a map.
    pub page_nodes: usize,
    pub page_controls: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub check: Option<CheckTrace>,
    pub at: String,
    /// When the harness got the look this entry answers, when the entry was written, and the
    /// time between: the harness's own time for the step, of which the model calls (their
    /// `startedAt` and `latencyMs`) are the part spent waiting on a provider.
    pub started_at: String,
    pub ended_at: String,
    pub duration_ms: i64,
    pub url: String,
    pub title: String,
    pub viewport: Viewport,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub focus: Option<Focus>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub results: Vec<ActionResult>,
    pub stale: u32,
    pub observation: String,
    pub memo: String,
    pub status: Status,
    pub message: String,
    /// The answer in words, on the step that ends the run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answer: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop: Option<StopInfo>,
    pub actions: Vec<TracedAction>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub dropped: Vec<String>,
    /// Why the step produced no answer (the model failed, the observation was refused).
    #[serde(skip_serializing_if = "String::is_empty")]
    pub error: String,
    /// The run's model use up to and including this step.
    pub usage: Usage,
}

/// An action as the trace writes it: as the browser gets it, plus what the harness kept of it,
/// and a typed secret hidden.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TracedAction {
    #[serde(flatten)]
    pub action: Action,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub label: String,
    #[serde(skip_serializing_if = "is_no_commit")]
    pub commit: Commit,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub check: String,
}

/// A check as the trace shows it.
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckTrace {
    pub expect: String,
    pub matches: f64,
    #[serde(default)]
    pub contradicted: f64,
    pub blocked: f64,
    pub loading: f64,
    pub outcome: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub reason: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub model: String,
    pub latency_ms: i64,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub error: String,
}

/// One call of a step to a model.
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelCall {
    /// `decision` for a call to the decision model; empty for the driving model.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub kind: String,
    /// Marks the second call, which tells the model its first answer was refused.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub repair: bool,
    pub messages: Vec<TracedMessage>,
    pub content: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub finish_reason: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub model: String,
    pub usage: Usage,
    pub latency_ms: i64,
    /// The history's estimated size when the request was built, against the size past which the
    /// history is compacted.
    #[serde(skip_serializing_if = "is_zero")]
    pub history_tokens: usize,
    #[serde(skip_serializing_if = "is_zero")]
    pub history_budget: usize,
    /// How many requests the call sent (a rate limit is retried).
    pub http_attempts: u32,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub error: String,
    pub started_at: String,
}

/// One message sent to the model, with its images counted, not embedded.
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TracedMessage {
    pub role: String,
    pub text: String,
    pub images: usize,
}

/// The run's start (`session.json`).
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionTrace<'a> {
    pub started: String,
    pub start: StartTrace<'a>,
    pub model: &'a str,
    /// The decision model that checks the screen, empty when none does.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub screen_model: String,
    pub config: &'a Config,
}

/// What the run was asked to do.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StartTrace<'a> {
    pub url: &'a str,
    pub goal: &'a str,
    pub survey: bool,
    /// How the model sees the page: `image` or `dom`.
    pub mode: crate::task::Mode,
    pub max_steps: u32,
}

impl ModelCall {
    /// A call to the driving model, as `recover::ask` made it.
    pub fn driving(call: &Call, history_tokens: usize, history_budget: usize) -> ModelCall {
        let mut out = ModelCall {
            repair: call.repair,
            messages: call.messages.iter().map(|sent| TracedMessage { role: role_name(sent.role).to_string(), text: sent.text.clone(), images: sent.images }).collect(),
            history_tokens,
            history_budget,
            http_attempts: 1,
            started_at: rfc3339(call.started),
            ..Default::default()
        };
        match &call.response {
            Ok(response) => {
                out.content = response.content.clone();
                out.finish_reason = response.finish_reason.clone();
                out.model = response.model.clone();
                out.usage = response.usage;
                out.latency_ms = response.latency.as_millis() as i64;
                out.http_attempts = response.attempts.max(1);
            }
            Err(error) => out.error = error.to_string(),
        }
        out
    }

    /// A call to the decision model: what it was asked, in a line, and what it answered.
    pub fn decision(prompt: &str, answered: Result<&Verdicts, &Error>, started: SystemTime) -> ModelCall {
        let mut out = ModelCall {
            kind: KIND_DECISION.to_string(),
            messages: vec![TracedMessage { role: "state".to_string(), text: prompt.to_string(), images: 1 }],
            http_attempts: 1,
            started_at: rfc3339(started),
            ..Default::default()
        };
        match answered {
            Ok(verdicts) => {
                out.content = serde_json::to_string(&verdicts.answers).unwrap_or_default();
                out.model = verdicts.model.clone();
                out.usage = verdicts.usage;
                out.latency_ms = verdicts.latency.as_millis() as i64;
            }
            Err(error) => out.error = error.to_string(),
        }
        if out.latency_ms == 0 {
            out.latency_ms = started.elapsed().unwrap_or_default().as_millis() as i64;
        }
        out
    }
}

fn role_name(role: Role) -> &'static str {
    match role {
        Role::System => "system",
        Role::User => "user",
        Role::Assistant => "assistant",
    }
}

/// The actions as the trace writes them: a typed secret is hidden.
pub fn traced_actions(actions: &[Action]) -> Vec<TracedAction> {
    actions
        .iter()
        .map(|action| {
            let mut copy = action.clone();
            if let Kind::Type { text, secret: true } = &mut copy.kind {
                *text = format!("[{} secret characters]", text.chars().count());
            }
            TracedAction { label: action.label.clone(), commit: action.commit, check: action.check.clone(), action: copy }
        })
        .collect()
}

impl Tracer {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Tracer { dir: dir.into() }
    }

    /// The run's folder, made if it is not there.
    fn folder(&self, id: &str) -> Result<PathBuf, String> {
        let dir = self.dir.join(id);
        fs::create_dir_all(&dir).map_err(|e| format!("make trace folder: {e}"))?;
        Ok(dir)
    }

    /// Writes files into the run's folder.
    fn write_files(&self, id: &str, files: &[(String, Vec<u8>)]) -> Result<(), String> {
        let dir = self.folder(id)?;
        for (name, data) in files {
            fs::write(dir.join(name), data).map_err(|e| format!("write {name}: {e}"))?;
        }
        Ok(())
    }

    /// Writes the run's start and the prompt the model is given.
    pub fn record_session(&self, id: &str, system: &str, info: &SessionTrace<'_>) -> Result<(), String> {
        let session = serde_json::to_vec_pretty(info).map_err(|e| format!("encode session.json: {e}"))?;
        self.write_files(id, &[("system.txt".to_string(), system.as_bytes().to_vec()), ("session.json".to_string(), session)])
    }

    /// Writes one entry: what the page reported and the model decided, every model call, the
    /// screenshot and the same screenshot with each action drawn on it (a survey's screens
    /// likewise), and a line of the timeline. `actions` are the entry's actions as sent.
    pub fn record(&self, id: &str, entry: &StepTrace, screenshot: &str, survey: &[SurveyScreen], page: Option<(&PageMap, &Viewport)>, actions: &[Action], calls: &[ModelCall]) -> Result<(), String> {
        let name = format!("{:03}", entry.seq);
        let mut files = vec![(format!("{name}.json"), serde_json::to_vec_pretty(entry).map_err(|e| format!("encode entry: {e}"))?)];
        if let Some((map, viewport)) = page {
            files.push((format!("{name}.page.txt"), map.text(viewport).into_bytes()));
        }
        if !calls.is_empty() {
            files.push((format!("{name}.model.json"), serde_json::to_vec_pretty(calls).map_err(|e| format!("encode calls: {e}"))?));
        }
        if let Some(comma) = screenshot.find(',') {
            let extension = if screenshot[..comma].contains("png") { "png" } else { "jpg" };
            if let Ok(raw) = change::decode_data_url(screenshot) {
                files.push((format!("{name}.{extension}"), raw));
            }
            if actions.iter().any(|a| a.point().is_some())
                && let Ok(marked) = mark::mark_screenshot(screenshot, actions)
                && let Ok(raw) = change::decode_data_url(&marked)
            {
                files.push((format!("{name}.marked.jpg"), raw));
            }
        }
        for (i, screen) in survey.iter().enumerate() {
            let Ok(raw) = change::decode_data_url(&screen.screenshot) else { continue };
            let stem = format!("{name}.survey{}", i + 1);
            files.push((format!("{stem}.jpg"), raw));
            let here: Vec<Action> = actions.iter().filter(|a| a.scroll_to == Some(screen.scroll_y)).cloned().collect();
            if here.iter().any(|a| a.point().is_some())
                && let Ok(marked) = mark::mark_screenshot(&screen.screenshot, &here)
                && let Ok(raw) = change::decode_data_url(&marked)
            {
                files.push((format!("{stem}.marked.jpg"), raw));
            }
        }
        self.write_files(id, &files)?;
        let dir = self.folder(id)?;
        let mut timeline = fs::OpenOptions::new().append(true).create(true).open(dir.join("timeline.txt")).map_err(|e| format!("open timeline: {e}"))?;
        writeln!(timeline, "{}", timeline_line(entry, actions, calls)).map_err(|e| format!("write timeline: {e}"))
    }
}

/// One line of the timeline for an entry.
fn timeline_line(entry: &StepTrace, actions: &[Action], calls: &[ModelCall]) -> String {
    let latency: i64 = calls.iter().map(|call| call.latency_ms).sum();
    let status = match &entry.check {
        Some(check) => format!("check:{}", check.outcome),
        None => serde_json::to_value(entry.status).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default(),
    };
    let mut line = format!("{:03} step {} {:<14} {:5}ms ${:.4}", entry.seq, entry.step, status, latency, entry.usage.cost);
    // Model time against the harness's whole time for the step, and when it began.
    line.push_str(&format!(" server={}ms at={}", entry.duration_ms, clock_of(&entry.started_at)));
    if let Some(check) = &entry.check {
        line.push_str(&format!(" match={:.2} blocked={:.2} loading={:.2}", check.matches, check.blocked, check.loading));
    }
    if entry.stale > 0 {
        line.push_str(&format!(" stale={}", entry.stale));
    }
    if !entry.error.is_empty() {
        line.push_str(&format!(" ERROR: {}", model::clip_text(&entry.error, TIMELINE_ERROR_CHARS)));
    }
    line.push_str(&format!(" | {}", model::clip_text(&entry.message, TIMELINE_MESSAGE_CHARS)));
    if let Some(answer) = &entry.answer {
        line.push_str(&format!(" | ANSWER: {}", model::clip_text(answer, TIMELINE_MESSAGE_CHARS)));
    }
    if !actions.is_empty() {
        line.push_str(&format!(" | {}", actions.iter().map(memory::describe).collect::<Vec<_>>().join("; ")));
    }
    if !entry.dropped.is_empty() {
        line.push_str(&format!(" | DROPPED: {}", entry.dropped.join("; ")));
    }
    line
}

/// The time of day of an RFC 3339 stamp, as `15:04:05.000`.
fn clock_of(stamp: &str) -> &str {
    stamp.get(11..23).unwrap_or(stamp)
}

/// A time as RFC 3339 in UTC, to the millisecond: `2026-10-22T12:34:56.789Z`.
pub fn rfc3339(at: SystemTime) -> String {
    let since = at.duration_since(UNIX_EPOCH).unwrap_or_default();
    let secs = since.as_secs() as i64;
    let (year, month, day) = civil_from_days(secs.div_euclid(86_400));
    let rem = secs.rem_euclid(86_400);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z", rem / 3600, rem % 3600 / 60, rem % 60, since.subsec_millis())
}

/// The proleptic Gregorian date of a day count since 1970-01-01 (H. Hinnant's civil-from-days).
pub(crate) fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + if month <= 2 { 1 } else { 0 };
    (year, month, day)
}

fn is_zero(n: &usize) -> bool {
    *n == 0
}

fn is_no_commit(commit: &Commit) -> bool {
    *commit == Commit::None
}

impl Agent {
    /// Writes every step of every run to a folder under `dir`, one folder per run.
    pub fn with_trace_dir(mut self, dir: impl Into<PathBuf>) -> Self {
        self.trace = Some(Tracer::new(dir));
        self
    }

    /// Writes one entry of the run to the trace, with the decision model's calls made since the
    /// last entry before the step's own. A trace that cannot be written never stops the run.
    pub(crate) fn record(&self, s: &mut Session, mut entry: StepTrace, screenshot: &str, survey: &[SurveyScreen], page: Option<&PageMap>, actions: &[Action], calls: Vec<ModelCall>) {
        let mut all = std::mem::take(&mut s.pending_calls);
        all.extend(calls);
        let Some(tracer) = &self.trace else { return };
        if let Some(map) = page {
            entry.page_nodes = map.nodes.len();
            entry.page_controls = map.controls();
        }
        let now = SystemTime::now();
        entry.started_at = rfc3339(s.step_started);
        entry.ended_at = rfc3339(now);
        entry.duration_ms = now.duration_since(s.step_started).unwrap_or_default().as_millis() as i64;
        entry.actions = traced_actions(actions);
        // A write that fails is the operator's to notice from the folder; the run goes on.
        let viewport = entry.viewport;
        let _ = tracer.record(&s.id, &entry, screenshot, survey, page.map(|map| (map, &viewport)), actions, &all);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::Profile;
    use crate::task::Task;
    use crate::testing::{Replying, Sure, look};
    use crate::verify::ASK_MATCHES;

    #[test]
    fn a_run_leaves_the_files_tracesum_reads() {
        let dir = std::env::temp_dir().join(format!("harness-trace-{}", std::process::id()));
        let reply = r#"{"observation":"a form","status":"working","message":"Filling.","actions":[{"kind":"click","x":10,"y":20,"label":"Name","check":"the box is focused"},{"kind":"type","text":"hunter2","secret":true}]}"#;
        let (model, _) = Replying::new(reply);
        let agent = Agent::new(Config::default(), model).with_decider(Sure::of(&[(ASK_MATCHES, 1.0)])).with_trace_dir(&dir);
        let id = agent.start(Task::new("fill the form"), Profile::default());
        agent.step(&id, look(false, &[])).unwrap();
        // The second look continues the plan on the checker's word: an entry of its own.
        agent.step(&id, look(true, &["s1a1"])).unwrap();
        let run = dir.join(&id);
        for name in ["session.json", "system.txt", "001.json", "001.model.json", "001.png", "001.marked.jpg", "002.json", "002.model.json", "timeline.txt"] {
            assert!(run.join(name).exists(), "{name} is missing");
        }
        let entry: serde_json::Value = serde_json::from_slice(&fs::read(run.join("001.json")).unwrap()).unwrap();
        assert_eq!(entry["status"], "working");
        assert_eq!(entry["actions"][0]["kind"], "click");
        assert_eq!(entry["actions"][0]["label"], "Name");
        // The point check's call comes first, then the driving model's.
        let calls: serde_json::Value = serde_json::from_slice(&fs::read(run.join("001.model.json")).unwrap()).unwrap();
        let calls = calls.as_array().unwrap();
        assert_eq!(calls.len(), 2, "{calls:?}");
        assert_eq!(calls[0]["kind"], "decision");
        assert!(calls[1]["kind"].is_null() && calls[1]["usage"]["inputTokens"] == 0 && calls[1]["messages"][0]["role"] == "system", "{:?}", calls[1]);
        // The typing went out as the second batch, on the checker's word, with its secret hidden.
        let check: serde_json::Value = serde_json::from_slice(&fs::read(run.join("002.json")).unwrap()).unwrap();
        assert_eq!(check["source"], "check");
        assert_eq!(check["check"]["outcome"], "continue");
        assert_eq!(check["actions"][0]["text"], "[7 secret characters]");
        let calls: serde_json::Value = serde_json::from_slice(&fs::read(run.join("002.model.json")).unwrap()).unwrap();
        assert_eq!(calls[0]["kind"], "decision");
        let timeline = fs::read_to_string(run.join("timeline.txt")).unwrap();
        assert!(timeline.starts_with("001 step 1 working"), "{timeline}");
        assert!(timeline.lines().nth(1).unwrap().starts_with("002 step 1 check:continue"), "{timeline}");
        assert_eq!(rfc3339(UNIX_EPOCH + std::time::Duration::from_millis(1_000_000_000_123)), "2001-09-09T01:46:40.123Z");
        fs::remove_dir_all(&dir).unwrap();
    }
}
