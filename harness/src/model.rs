//! Talking to the driving model: the reply it must give, the JSON schema that shapes it, reading
//! it, and turning the actions it wrote into ones the browser can run.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::action::{Action, Commit, Kind};
use crate::observe::Viewport;
use crate::run::{Status, StopInfo};

/// The name the reply schema is sent under.
pub const REPLY_SCHEMA_NAME: &str = "step";
/// The most characters the model's memo may hold.
pub const MAX_MEMO_CHARS: usize = 2000;

// Limits on what one step may ask for.
const MAX_TYPE_CHARS: usize = 2000;
const MAX_KEY_TOKENS: usize = 12;
const MIN_WAIT_MS: u64 = 100;
const MAX_WAIT_MS: u64 = 10_000;
const MAX_SCROLL_PAGES: f64 = 3.0;
const MAX_CHECK_CHARS: usize = 300;
const MAX_LABEL_CHARS: usize = 80;
const DEFAULT_WAIT_MS: u64 = 1000;

/// What the model answers at each step.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reply {
    /// What the model sees on the screen, in a sentence or two: it reads before it decides.
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
    /// A question for the person that the run can go on without an answer to; `None` when there
    /// is none this step.
    #[serde(default)]
    pub question: Option<String>,
    /// The facts and choices the model took for the person on this step without being told, one
    /// line each; `None` when it took none.
    #[serde(default)]
    pub assumed: Option<Vec<String>>,
    /// The screens of a survey the model will not need to come back to; `None` when the look is
    /// not a survey.
    #[serde(default)]
    pub settled: Option<Vec<u32>>,
    /// Every question of the form as the model reads it on a survey, with where it is and whether
    /// it is answered; `None` when the look is not a survey.
    #[serde(default)]
    pub fields: Option<Vec<RawField>>,
    /// The actions as written; `check_actions` turns them into ones the browser can run.
    #[serde(default)]
    pub actions: Vec<RawAction>,
}

/// One question of the form as the model reads it: its label, where it is on the survey, and its
/// state (`filled`, `empty`, `optional`, `needs_person`).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct RawField {
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub screen: Option<u32>,
    #[serde(default)]
    pub y: Option<f64>,
    #[serde(default)]
    pub state: String,
}

/// One action as the model wrote it: every field optional, checked before it becomes an
/// [`Action`].
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct RawAction {
    #[serde(default)]
    pub kind: String,
    /// The survey screen the point is measured on, from 1.
    #[serde(default)]
    pub screen: Option<u32>,
    #[serde(default)]
    pub x: Option<f64>,
    #[serde(default)]
    pub y: Option<f64>,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub secret: Option<bool>,
    #[serde(default)]
    pub keys: Option<String>,
    #[serde(default)]
    pub dx: Option<f64>,
    #[serde(default)]
    pub dy: Option<f64>,
    #[serde(default)]
    pub ms: Option<u64>,
    #[serde(default)]
    pub resource: Option<String>,
    #[serde(default)]
    pub check: Option<String>,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default)]
    pub commit: Option<String>,
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

/// Turns the model's actions into ones the browser can run, and says why it refused the rest.
/// An action that would land outside the screenshot, type nothing, or press no key is refused
/// here, so the browser never receives a nonsense command. `screens` are the scroll positions
/// of the survey the look was, empty for a plain look.
pub fn check_actions(step: u32, raw: Vec<RawAction>, vp: &Viewport, max_actions: usize, screens: &[f64]) -> (Vec<Action>, Vec<String>) {
    let mut valid = Vec::new();
    let mut dropped = Vec::new();
    for (i, input) in raw.into_iter().enumerate() {
        let n = i + 1;
        if valid.len() >= max_actions {
            dropped.push(format!("action {n} ({}): only {max_actions} actions run per step", input.kind));
            continue;
        }
        let kind = match fill(&input, vp) {
            Ok(kind) => kind,
            Err(why) => {
                dropped.push(format!("action {n} ({}): {why}", input.kind));
                continue;
            }
        };
        let mut action = Action::new(format!("s{step}a{n}"), kind);
        if let Err(why) = place_on_screen(&mut action, input.screen, vp, screens) {
            dropped.push(format!("action {n} ({}): {why}", input.kind));
            continue;
        }
        action.check = clip_text(input.check.as_deref().unwrap_or("").trim(), MAX_CHECK_CHARS);
        action.label = clip_text(input.label.as_deref().unwrap_or("").trim(), MAX_LABEL_CHARS);
        action.commit = commit_of(&input, &action.kind);
        valid.push(action);
    }
    (valid, dropped)
}

/// The kind an action is, with what it carries, once its fields are checked.
fn fill(input: &RawAction, vp: &Viewport) -> Result<Kind, String> {
    Ok(match input.kind.as_str() {
        "click" => {
            let (x, y) = point(input, vp)?;
            Kind::Click { x, y }
        }
        "double_click" => {
            let (x, y) = point(input, vp)?;
            Kind::DoubleClick { x, y }
        }
        "triple_click" => {
            let (x, y) = point(input, vp)?;
            Kind::TripleClick { x, y }
        }
        "right_click" => {
            let (x, y) = point(input, vp)?;
            Kind::RightClick { x, y }
        }
        "hover" => {
            let (x, y) = point(input, vp)?;
            Kind::Hover { x, y }
        }
        "upload" => {
            let (x, y) = point(input, vp)?;
            Kind::Upload { x, y, resource: input.resource.as_deref().unwrap_or("").trim().to_string(), file_name: String::new() }
        }
        "type" => {
            let text = input.text.clone().unwrap_or_default();
            if text.is_empty() {
                return Err("there is no text to type".to_string());
            }
            if text.chars().count() > MAX_TYPE_CHARS {
                return Err(format!("the text is longer than {MAX_TYPE_CHARS} characters"));
            }
            Kind::Type { text, secret: input.secret.unwrap_or(false) }
        }
        "key" => {
            let keys = input.keys.as_deref().unwrap_or("").trim().to_string();
            if keys.is_empty() {
                return Err("there is no key to press".to_string());
            }
            if keys.split_whitespace().count() > MAX_KEY_TOKENS {
                return Err(format!("more than {MAX_KEY_TOKENS} keys"));
            }
            Kind::Key { keys }
        }
        "scroll" => {
            let (dx, dy) = (input.dx.unwrap_or(0.0), input.dy.unwrap_or(0.0));
            if dx == 0.0 && dy == 0.0 {
                return Err("there is no distance to scroll".to_string());
            }
            // A scroll with no point scrolls where the page's middle is.
            let (x, y) = match (input.x, input.y) {
                (Some(x), Some(y)) if inside(x, y, vp) => (x, y),
                _ => (vp.width as f64 / 2.0, vp.height as f64 / 2.0),
            };
            Kind::Scroll {
                x: Some(x),
                y: Some(y),
                dx: dx.clamp(-MAX_SCROLL_PAGES * vp.width as f64, MAX_SCROLL_PAGES * vp.width as f64),
                dy: dy.clamp(-MAX_SCROLL_PAGES * vp.height as f64, MAX_SCROLL_PAGES * vp.height as f64),
            }
        }
        "wait" => Kind::Wait { ms: input.ms.unwrap_or(DEFAULT_WAIT_MS).clamp(MIN_WAIT_MS, MAX_WAIT_MS) },
        "survey" => Kind::Survey,
        _ => return Err("that is not an action the harness can send".to_string()),
    })
}

/// The action's point, when it has one inside the screenshot.
fn point(input: &RawAction, vp: &Viewport) -> Result<(f64, f64), String> {
    match (input.x, input.y) {
        (Some(x), Some(y)) if inside(x, y, vp) => Ok((x, y)),
        (Some(x), Some(y)) => Err(format!("the point ({x:.0}, {y:.0}) lies outside the {}x{} screenshot", vp.width, vp.height)),
        _ => Err("the action has no point".to_string()),
    }
}

fn inside(x: f64, y: f64, vp: &Viewport) -> bool {
    x.is_finite() && y.is_finite() && x >= 0.0 && x <= vp.width as f64 && y >= 0.0 && y <= vp.height as f64
}

/// Binds a point action to the survey screen its point was measured on: the browser scrolls
/// there before the action. Typing and keys follow the action before them.
fn place_on_screen(action: &mut Action, screen: Option<u32>, vp: &Viewport, screens: &[f64]) -> Result<(), String> {
    let Some(screen) = screen else { return Ok(()) };
    if action.point().is_none() || screens.is_empty() {
        return Ok(());
    }
    let index = screen.max(1) as usize;
    if index > screens.len() {
        return Err(format!("there is no screen {screen} (the survey has {})", screens.len()));
    }
    action.scroll_to = Some(screens[index - 1]);
    action.page_height = vp.page_height;
    action.zone = index as u32;
    Ok(())
}

/// What a click does beyond the click, when the model said and the action is a click.
fn commit_of(input: &RawAction, kind: &Kind) -> Commit {
    if !matches!(kind, Kind::Click { .. }) {
        return Commit::None;
    }
    match input.commit.as_deref().map(str::trim) {
        Some("next") => Commit::Next,
        Some("send") => Commit::Send,
        Some("pay") => Commit::Pay,
        Some("post") => Commit::Post,
        Some("delete") => Commit::Delete,
        Some("create_account") => Commit::CreateAccount,
        _ => Commit::None,
    }
}

/// The first `max_chars` characters of the text.
pub fn clip_text(text: &str, max_chars: usize) -> String {
    match text.char_indices().nth(max_chars) {
        Some((end, _)) => text[..end].to_string(),
        None => text.to_string(),
    }
}

/// The JSON schema the reply must fit. A provider's strict mode needs every property of an
/// object present, so an action is one of several shapes, each with only the fields its kind
/// uses: a click is not twelve fields with nine of them null. The order of the properties is the
/// order the model writes them in: the observation first, so it reads the screen before it
/// decides, and the actions last.
pub fn reply_schema(survey: bool, checks: bool) -> Value {
    let string = json!({"type": "string"});
    let null_string = json!({"type": ["string", "null"]});
    let number = json!({"type": "number"});
    let null_number = json!({"type": ["number", "null"]});
    let point = |kinds: &[&str], extra: Vec<(&str, Value)>| -> Value {
        let mut fields = vec![("kind", kind_enum(kinds))];
        if survey {
            fields.push(("screen", json!({"type": ["integer", "null"]})));
        }
        fields.push(("x", number.clone()));
        fields.push(("y", number.clone()));
        fields.push(("label", null_string.clone()));
        fields.extend(extra);
        if checks {
            fields.push(("check", null_string.clone()));
        }
        object(fields)
    };
    let plain = |kind: &str, extra: Vec<(&str, Value)>| -> Value {
        let mut fields = vec![("kind", kind_enum(&[kind]))];
        fields.extend(extra);
        if checks {
            fields.push(("check", null_string.clone()));
        }
        object(fields)
    };
    let mut shapes = vec![
        point(&["click", "double_click", "triple_click", "right_click", "hover"], vec![("commit", json!({"anyOf": [{"type": "null"}, {"type": "string", "enum": ["next", "send", "pay", "post", "delete", "create_account"]}]}))]),
        point(&["upload"], vec![("resource", null_string.clone())]),
        plain("type", vec![("text", string.clone()), ("secret", json!({"type": ["boolean", "null"]}))]),
        plain("key", vec![("keys", string.clone())]),
        plain("scroll", vec![("x", null_number.clone()), ("y", null_number.clone()), ("dx", number.clone()), ("dy", number.clone())]),
        object(vec![("kind", kind_enum(&["wait"])), ("ms", json!({"type": "integer"}))]),
    ];
    if survey {
        shapes.push(object(vec![("kind", kind_enum(&["survey"]))]));
    }
    let stop = json!({"anyOf": [{"type": "null"}, object(vec![
        ("reason", json!({"type": "string", "enum": ["captcha", "verification_code", "verification_link", "identity", "payment", "credentials", "account_rejected", "unavailable", "decision", "page_problem", "other"]})),
        ("problem", string.clone()),
        ("action", string.clone()),
    ])]});
    let mut fields = vec![
        ("observation", string.clone()),
        ("memo", null_string.clone()),
        ("status", json!({"type": "string", "enum": ["working", "done", "need_person", "stuck"]})),
        ("message", string.clone()),
        ("stop", stop),
        ("question", null_string.clone()),
        ("assumed", json!({"type": ["array", "null"], "items": {"type": "string"}})),
    ];
    if survey {
        // The screens the model will not come back to: asked last of the notes, before the plan.
        fields.push(("settled", json!({"type": ["array", "null"], "items": {"type": "integer"}})));
        // Every question of the form as the model reads it, with its state: the run's to-do list.
        let field = object(vec![
            ("label", string.clone()),
            ("screen", json!({"type": "integer"})),
            ("y", number.clone()),
            ("state", json!({"type": "string", "enum": ["filled", "empty", "optional", "needs_person"]})),
        ]);
        fields.push(("fields", json!({"type": ["array", "null"], "items": field})));
    }
    fields.push(("actions", json!({"type": "array", "items": {"anyOf": shapes}})));
    object(fields)
}

/// A strict object schema over fields, in order.
fn object(fields: Vec<(&str, Value)>) -> Value {
    let mut properties = Map::new();
    let mut required = Vec::new();
    for (name, schema) in fields {
        required.push(Value::String(name.to_string()));
        properties.insert(name.to_string(), schema);
    }
    json!({"type": "object", "additionalProperties": false, "required": required, "properties": properties})
}

fn kind_enum(kinds: &[&str]) -> Value {
    json!({"type": "string", "enum": kinds})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw(json: &str) -> RawAction {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn actions_are_checked_placed_and_named() {
        let vp = Viewport { width: 800, height: 600, page_height: 3000.0, ..Default::default() };
        let raw = vec![
            raw(r#"{"kind":"click","screen":2,"x":100,"y":50,"label":"Send","commit":"send","check":"a thank-you"}"#),
            raw(r#"{"kind":"type","text":""}"#),
            raw(r#"{"kind":"wait","ms":5}"#),
            raw(r#"{"kind":"scroll","dy":99999}"#),
            raw(r#"{"kind":"click","x":900,"y":50}"#),
            raw(r#"{"kind":"survey"}"#),
            raw(r#"{"kind":"dance"}"#),
        ];
        let (valid, dropped) = check_actions(3, raw, &vp, 30, &[0.0, 500.0]);
        let ids: Vec<&str> = valid.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, vec!["s3a1", "s3a3", "s3a4", "s3a6"]);
        assert_eq!(valid[0].scroll_to, Some(500.0));
        assert_eq!(valid[0].zone, 2);
        assert_eq!(valid[0].commit, Commit::Send);
        assert_eq!(valid[0].label, "Send");
        assert_eq!(valid[1].kind, Kind::Wait { ms: 100 });
        assert_eq!(valid[2].kind, Kind::Scroll { x: Some(400.0), y: Some(300.0), dx: 0.0, dy: 1800.0 });
        assert_eq!(valid[3].kind, Kind::Survey);
        assert_eq!(dropped.len(), 3);
    }

    #[test]
    fn the_reply_is_read_past_leading_text_and_the_schema_keeps_its_order() {
        let reply = parse_reply("Sure. {\"status\":\"working\",\"message\":\"\",\"actions\":[{\"kind\":\"wait\",\"ms\":100}]}").unwrap();
        assert_eq!(reply.status, Status::Working);
        assert_eq!(reply.actions[0].kind, "wait");
        assert!(parse_reply("").is_err());
        let schema = reply_schema(true, true).to_string();
        assert!(schema.find("\"observation\"").unwrap() < schema.find("\"actions\"").unwrap());
        assert!(schema.contains("\"survey\""));
        assert!(schema.contains("\"needs_person\""));
        let plain = reply_schema(false, false).to_string();
        assert!(!plain.contains("\"check\"") && !plain.contains("\"fields\""));
    }
}
