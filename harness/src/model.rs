//! Talking to the driving model: the system prompt, the observation text, the reply schema, and
//! parsing the reply.
//!
//! This is the minimal form that lets a step run end to end. The prompt text, the schema, and
//! the checks on the reply are filled out in their own steps.

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::action::Action;
use crate::observe::{ActionResult, Observation};
use crate::profile::Profile;
use crate::run::{Status, StopInfo};
use crate::task::Task;

/// The name the reply schema is sent under.
pub const REPLY_SCHEMA_NAME: &str = "step";
/// The most characters the model's memo may hold.
pub const MAX_MEMO_CHARS: usize = 2000;

/// What the model answers at each step.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reply {
    /// What the model sees on the screen, in a sentence or two: its reasoning's anchor.
    #[serde(default)]
    pub observation: String,
    /// The model's notes to itself for the rest of the run. `None` leaves the notes as they were.
    #[serde(default)]
    pub memo: Option<String>,
    pub status: Status,
    /// One line for the person: what the model is doing, or why it stopped.
    #[serde(default)]
    pub message: String,
    /// Why the run ends for the person, when it does.
    #[serde(default)]
    pub stop: Option<StopInfo>,
    #[serde(default)]
    pub actions: Vec<Action>,
}

/// Reads the model's answer. The answer may carry text before the JSON; it is skipped.
pub fn parse_reply(content: &str) -> Result<Reply, String> {
    let content = content.trim();
    if content.is_empty() {
        return Err("the model sent an empty answer".to_string());
    }
    let content = match content.find('{') {
        Some(start) => &content[start..],
        None => return Err("the model's answer holds no JSON object".to_string()),
    };
    serde_json::from_str(content).map_err(|e| format!("the model's answer is not the requested JSON: {e}"))
}

/// The standing instruction, the same on every step of a run so the provider can cache it.
pub fn system_prompt(task: &Task, profile: &Profile) -> String {
    let mut out = String::new();
    out.push_str("You drive a web browser to do one task for a person. At each step you see a screenshot of the page and answer with the next actions, as JSON.\n\n");
    out.push_str("Task: ");
    out.push_str(task.goal.trim());
    out.push('\n');
    if !task.done_when.trim().is_empty() {
        out.push_str("Done when: ");
        out.push_str(task.done_when.trim());
        out.push('\n');
    }
    if !profile.facts.trim().is_empty() {
        out.push_str("\nAbout the person:\n");
        out.push_str(profile.facts.trim());
        out.push('\n');
    }
    out.push_str("\nCoordinates are pixels in the screenshot you are shown. Report status \"working\" with actions, \"done\" when the screen shows the task is complete, \"need_person\" with a stop when only the person can go on, or \"stuck\" when you cannot.\n");
    out
}

/// What the model is told about a step beside the screenshot itself.
pub fn observation_text(step: u32, max_steps: u32, obs: &Observation, results: &[ActionResult], notes: &[String], memo: &str, stale: u32) -> String {
    let mut out = format!("Step {step} of at most {max_steps}.\n");
    out.push_str(&format!("Page: {} ({})\n", or_none(&obs.title), or_none(&obs.url)));
    let v = &obs.viewport;
    out.push_str(&format!(
        "Screenshot: {}x{} pixels, scrolled to {:.0} of a page {:.0} pixels tall.\n",
        v.width, v.height, v.scroll_y, v.page_height
    ));
    if let Some(focus) = &obs.focus {
        out.push_str(&format!("Focus: {} {} {:?}\n", focus.tag, focus.kind, focus.label));
    }
    if !obs.survey.is_empty() {
        out.push_str(&format!("Survey: {} screens of the whole page follow, top to bottom.\n", obs.survey.len()));
    }
    if !results.is_empty() {
        out.push_str("Results of your last actions:\n");
        for r in results {
            out.push_str(&format!("- {}\n", result_line(r)));
        }
    }
    for note in obs.notes.iter().chain(notes) {
        out.push_str(&format!("Note: {note}\n"));
    }
    if stale >= 1 {
        out.push_str(&format!(
            "The screen has not changed for {stale} step(s): your last actions had no visible effect. Look again at where you clicked and do something different.\n"
        ));
    }
    if !memo.is_empty() {
        out.push_str(&format!("\nYour notes so far:\n{memo}\n"));
    }
    out
}

fn result_line(r: &ActionResult) -> String {
    let mut line = format!("{}: {}", r.id, if r.ok { "ok" } else { "failed" });
    if !r.error.is_empty() {
        line.push_str(&format!(" ({})", r.error));
    }
    if !r.detail.is_empty() {
        line.push_str(&format!(" {}", r.detail));
    }
    if r.unreached {
        line.push_str(" [reached no control]");
    }
    line
}

fn or_none(s: &str) -> &str {
    if s.trim().is_empty() { "none" } else { s.trim() }
}

/// The JSON schema the reply must fit.
pub fn reply_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["observation", "memo", "status", "message", "stop", "actions"],
        "properties": {
            "observation": {"type": "string"},
            "memo": {"type": ["string", "null"]},
            "status": {"type": "string", "enum": ["working", "done", "need_person", "stuck"]},
            "message": {"type": "string"},
            "stop": {"type": ["object", "null"], "additionalProperties": false,
                "required": ["reason", "problem", "action"],
                "properties": {
                    "reason": {"type": "string"},
                    "problem": {"type": "string"},
                    "action": {"type": "string"}
                }},
            "actions": {"type": "array", "items": {"type": "object"}}
        }
    })
}
