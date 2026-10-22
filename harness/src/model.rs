//! Talking to the driving model: the system prompt, the observation text, the reply schema, and
//! parsing the reply.
//!
//! This is the minimal form that lets a step run end to end. The prompt text, the schema, and
//! the checks on the reply are filled out in their own steps.

use serde::{Deserialize, Serialize};
use serde_json::json;

use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::action::Action;
use crate::observe::{ActionResult, Observation};
use crate::profile::Profile;
use crate::run::{Config, Status, StopInfo};
use crate::task::{Allowance, Irreversible, StopReason, Task};

/// The standing instruction, as a template: `{{key}}` is filled in, and `{{#if key}}...{{/if}}`
/// stays only when the key has a value.
const SYSTEM_TEMPLATE: &str = include_str!("prompts/system.md");

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

/// The standing instruction, the same on every step of a run so the provider can cache it: the
/// task, how to answer, when to stop, what the person allows, and who they are.
pub fn system_prompt(task: &Task, profile: &Profile, config: &Config) -> String {
    let mut values: BTreeMap<&str, String> = BTreeMap::new();
    values.insert("goal", task.goal.trim().to_string());
    values.insert("done_when", task.done_when.trim().to_string());
    values.insert("max_actions", config.max_actions.to_string());
    values.insert("chunk", config.chunk_actions.to_string());
    values.insert("stop_reasons", stop_reason_lines(task));
    values.insert("allowances", allowance_lines(task));
    values.insert("survey", if task.survey { "yes".to_string() } else { String::new() });
    values.insert("checks", if config.checks { "yes".to_string() } else { String::new() });
    values.insert("profile", if profile.facts.trim().is_empty() { "The person gave no details about themselves.".to_string() } else { profile.facts.trim().to_string() });
    values.insert(
        "resources",
        task.resources.iter().map(|r| format!("- {}: {} ({})", r.id, r.description.trim(), r.name)).collect::<Vec<_>>().join("\n"),
    );
    values.insert("today", today().unwrap_or_default());
    render(SYSTEM_TEMPLATE, &values)
}

/// Fills a template: `{{#if key}}...{{/if}}` blocks stay when the key has a non-empty value and
/// go when it does not; then every `{{key}}` is replaced. Blocks do not nest.
pub fn render(template: &str, values: &BTreeMap<&str, String>) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(start) = rest.find("{{#if ") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 6..];
        let Some(name_end) = after.find("}}") else { break };
        let name = after[..name_end].trim();
        let body = &after[name_end + 2..];
        let Some(close) = body.find("{{/if}}") else { break };
        if values.get(name).is_some_and(|v| !v.is_empty()) {
            out.push_str(&body[..close]);
        }
        rest = &body[close + 7..];
    }
    out.push_str(rest);
    for (key, value) in values {
        out = out.replace(&format!("{{{{{key}}}}}"), value);
    }
    out
}

/// One line per reason the model may stop for under this task's policy.
fn stop_reason_lines(task: &Task) -> String {
    let mut lines: Vec<String> = task
        .persistence
        .stop_for
        .iter()
        .filter_map(|reason| stop_reason_text(*reason).map(|text| format!("- reason \"{}\": {text}", reason_name(*reason))))
        .collect();
    lines.push("For any other reason, keep going: the harness sends such a stop back with a note.".to_string());
    lines.join("\n")
}

fn stop_reason_text(reason: StopReason) -> Option<&'static str> {
    Some(match reason {
        StopReason::Captcha => "a CAPTCHA or another check that they are human, one that stands in the way (a box to tick, a puzzle to solve, a challenge over the page). A badge or notice saying the page is protected by such a service is not a check, and a check that only comes once the button is pressed is met then: press the button first.",
        StopReason::VerificationCode => "a code sent to their e-mail or phone that you were not given.",
        StopReason::VerificationLink => "a link in an e-mail they must open.",
        StopReason::Identity => "an identity number or document you do not have (a national ID, a passport, a driver's license), or a legal signature.",
        StopReason::Payment => "money: a payment, a card, a subscription, unless the person allowed it below.",
        StopReason::Credentials => "a sign-in you have no password for, and the browser does not fill in.",
        StopReason::AccountRejected => "an account the site will not accept: the sign-in, the sign-up, and the password reset all failed.",
        StopReason::Unavailable => "the page makes clear the task cannot be done here (closed, offline only, the wrong page). Report this one as \"stuck\".",
        StopReason::Decision => "a choice only the person can make, with real consequences either way, that nothing you know settles.",
        StopReason::Other => "something else that truly needs the person; say exactly what.",
        _ => return None,
    })
}

fn reason_name(reason: StopReason) -> String {
    serde_json::to_value(reason).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default()
}

/// One line per kind of irreversible action, saying what the person allows.
fn allowance_lines(task: &Task) -> String {
    [
        (Irreversible::Send, "send", "submit, send, apply, place an order"),
        (Irreversible::Pay, "pay", "pay, enter a card, start a subscription"),
        (Irreversible::Post, "post", "publish where others see it"),
        (Irreversible::Delete, "delete", "delete or cancel something that exists"),
        (Irreversible::CreateAccount, "create an account", "sign up"),
    ]
    .iter()
    .map(|(kind, name, examples)| {
        let rule = match task.allowance(*kind) {
            Allowance::Auto => "allowed: go ahead when the task needs it",
            Allowance::Ask => "ask first: the harness holds the click and asks the person; go on with the rest meanwhile",
            Allowance::Never => "never: the harness holds the click, and the run ends as ready for the person to do it",
        };
        format!("- {name} ({examples}): {rule}.")
    })
    .collect::<Vec<_>>()
    .join("\n")
}

/// Today's date as `YYYY-MM-DD` in UTC, when the clock gives one.
fn today() -> Option<String> {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs();
    let days = (secs / 86_400) as i64;
    // Civil-from-days (H. Hinnant): days since 1970-01-01 to a proleptic Gregorian date.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    Some(format!("{y:04}-{m:02}-{d:02}"))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_prompt_follows_the_task_and_the_template_blocks_follow_their_keys() {
        let mut values = BTreeMap::new();
        values.insert("a", "A".to_string());
        values.insert("b", String::new());
        assert_eq!(render("x{{#if a}}[{{a}}]{{/if}}{{#if b}}[{{b}}]{{/if}}y", &values), "x[A]y");

        let mut task = Task::new("Buy a kettle.").allow(Irreversible::Pay, Allowance::Auto);
        task.survey = false;
        let prompt = system_prompt(&task, &Profile::new("Name: B."), &Config::default());
        assert!(prompt.contains("Buy a kettle."));
        assert!(prompt.contains("- pay (pay, enter a card, start a subscription): allowed"));
        assert!(prompt.contains("- send (submit, send, apply, place an order): ask first"));
        assert!(prompt.contains("reason \"captcha\""));
        assert!(!prompt.contains("# Seeing the whole page"));
        assert!(!prompt.contains("{{"));
        task.survey = true;
        assert!(system_prompt(&task, &Profile::default(), &Config::default()).contains("# Seeing the whole page"));
    }
}
