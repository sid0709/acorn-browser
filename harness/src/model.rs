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
use crate::observe::{ActionResult, Focus, Observation, Opened, Viewport};
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

/// What the model is told about a step beside the screenshot itself: where the run stands, the
/// page, the window onto it, what has focus, what became of the last actions, the notes, and the
/// model's own memo. Only the newest step carries the memo in full, so it is paid for once.
pub fn observation_text(step: u32, max_steps: u32, obs: &Observation, results: &[ActionResult], notes: &[String], memo: &str, stale: u32) -> String {
    let mut out = format!("Step {step} of at most {max_steps}.\n");
    out.push_str(&format!("Page: {} ({})\n", or_none(&obs.title), or_none(&obs.url)));
    out.push_str(&format!("Screenshot: {}x{} pixels. {}\n", obs.viewport.width, obs.viewport.height, scroll_line(&obs.viewport)));
    out.push_str(&focus_line(obs.focus.as_ref()));
    if !obs.survey.is_empty() {
        out.push_str(&survey_line(obs));
    }
    if !results.is_empty() {
        out.push_str("Results of your last actions:\n");
        for result in results {
            out.push_str(&format!("- {}\n", result_line(result)));
        }
    }
    for note in obs.notes.iter().chain(notes) {
        out.push_str(&format!("Note: {}\n", note.trim()));
    }
    if stale >= 1 {
        out.push_str(&format!(
            "Check: the screen looks the same as after your previous actions ({stale} step{} in a row). If error text still shows but the fields already look filled, do not refill them; press the button again, the text may be left from an earlier try. Otherwise find out why before you repeat the same edit.\n",
            plural(stale)
        ));
    }
    let memo = memo.trim();
    if memo.is_empty() {
        out.push_str("Your notes so far: (none yet)\n");
    } else {
        out.push_str(&format!("Your notes so far:\n{memo}\n"));
    }
    out.push_str("Answer with the JSON object.");
    out
}

/// How much of the page lies off screen, so the model knows whether to scroll.
fn scroll_line(v: &Viewport) -> String {
    if v.page_height <= 0.0 {
        return String::new();
    }
    let below = v.page_height - v.scroll_y - v.height as f64;
    let above = v.scroll_y;
    match (above > 8.0, below > 8.0) {
        (true, true) => format!("The page is scrolled: about {above:.0} px lies above and {below:.0} px below."),
        (false, true) => format!("The page is at its top; about {below:.0} px lies below."),
        (true, false) => format!("The page is at its bottom; about {above:.0} px lies above."),
        (false, false) => "The whole page fits on the screen.".to_string(),
    }
}

/// Which control has the keyboard, by the name the page gives it, so the model knows where
/// typing goes. What the page says of the control's kind, value or state is not told: the
/// screenshot shows that, and the page's own word lies for a control it draws itself. The
/// options of a list the browser draws are the one thing told, since no screenshot shows that
/// popup.
fn focus_line(focus: Option<&Focus>) -> String {
    let Some(focus) = focus else {
        return "Keyboard focus: no control.\n".to_string();
    };
    let name = if focus.label.trim().is_empty() {
        "a control the page does not name".to_string()
    } else {
        format!("the control labelled {:?}", focus.label.trim())
    };
    let mut line = format!("Keyboard focus: {name}.\n");
    if focus.tag.eq_ignore_ascii_case("select") && !focus.options.is_empty() {
        let several = if focus.multiple { " (several may be chosen)" } else { "" };
        line.push_str(&format!(
            "It is a list the browser draws itself, which no screenshot shows. Its options{several}: {}.\n",
            focus.options.join(" | ")
        ));
    }
    line
}

/// The screens of a survey: how many, and where each is scrolled to.
fn survey_line(obs: &Observation) -> String {
    let positions: Vec<String> = obs.survey.iter().enumerate().map(|(i, screen)| format!("{} at {:.0} px", i + 1, screen.scroll_y)).collect();
    format!(
        "This look is a survey of the whole page: {} screens, numbered on each picture, from the top down. Screen {}.\n",
        obs.survey.len(),
        positions.join(", screen ")
    )
}

/// One line for what became of one action.
fn result_line(result: &ActionResult) -> String {
    let mut line = format!("{} {}", result.id, if result.ok { "done" } else { "failed" });
    if !result.error.is_empty() {
        line.push_str(&format!(": {}", result.error));
    }
    if result.opened == Some(Opened::FilePicker) {
        line.push_str(" (this click opened a file picker that you cannot see, and no file was chosen: to attach a file, use upload at this point)");
    }
    if result.unreached {
        line.push_str(" (nothing had focus, so it reached no control)");
    }
    if !result.detail.is_empty() {
        line.push_str(&format!(" ({})", result.detail));
    }
    line
}

fn or_none(text: &str) -> &str {
    let text = text.trim();
    if text.is_empty() { "none" } else { text }
}

fn plural(n: u32) -> &'static str {
    if n == 1 { "" } else { "s" }
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

    #[test]
    fn the_observation_text_says_where_the_run_stands() {
        let obs = Observation {
            title: "Checkout".into(),
            url: "https://shop.test/pay".into(),
            viewport: Viewport { width: 800, height: 600, scroll_y: 300.0, page_height: 2000.0, ..Default::default() },
            focus: Some(Focus { tag: "select".into(), label: "Country".into(), options: vec!["France".into(), "Spain".into()], ..Default::default() }),
            ..Default::default()
        };
        let results = vec![ActionResult { id: "s1a1".into(), ok: false, error: "nothing at that point".into(), ..Default::default() }];
        let text = observation_text(2, 150, &obs, &results, &["the file was attached".to_string()], "pay by card", 1);
        assert!(text.starts_with("Step 2 of at most 150.\nPage: Checkout (https://shop.test/pay)\n"));
        assert!(text.contains("about 300 px lies above and 1100 px below"));
        assert!(text.contains("labelled \"Country\""));
        assert!(text.contains("France | Spain"));
        assert!(text.contains("- s1a1 failed: nothing at that point"));
        assert!(text.contains("Note: the file was attached"));
        assert!(text.contains("(1 step in a row)"));
        assert!(text.ends_with("Your notes so far:\npay by card\nAnswer with the JSON object."));
    }
}
