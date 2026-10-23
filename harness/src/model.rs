//! Talking to the driving model: the reply it must give, the JSON schema that shapes it, reading
//! it, and turning the actions it wrote into ones the browser can run.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::action::{Action, Commit, Kind, Point, Target};
use crate::check::Check;
use crate::observe::Viewport;
use crate::page::PageMap;
use crate::run::{Status, StopInfo};

/// The name the reply schema is sent under.
pub const REPLY_SCHEMA_NAME: &str = "step";
/// The most characters the model's memo may hold.
pub const MAX_MEMO_CHARS: usize = 2000;

// Limits on what one step may ask for.
const MAX_TYPE_CHARS: usize = 2000;
const MAX_KEY_TOKENS: usize = 12;
/// The most points a drag's path may have: a long stroke is many close points.
const MAX_PATH_POINTS: usize = 400;
const MIN_WAIT_MS: u64 = 100;
const MAX_WAIT_MS: u64 = 30_000;
/// The longest address the model may go to.
const MAX_URL_CHARS: usize = 2000;
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
    /// With "done": what on the screen shows the task done, in the model's words, for the
    /// checker to look for. `None` when the model gave none.
    #[serde(default)]
    pub proof: Option<String>,
    /// With "done" (or with a stop, for what was found so far): the answer to what the task
    /// asks, in words read from the page: the figure, the name, the count, the conclusion. For
    /// a task that asks for a state rather than a fact, what was done and what the page shows.
    #[serde(default)]
    pub answer: Option<String>,
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
    /// Keys held during a click or a drag: "Shift", "Meta+Shift".
    #[serde(default)]
    pub modifiers: Option<String>,
    /// A drag's points, in order.
    #[serde(default)]
    pub path: Option<Vec<RawPoint>>,
    /// Where to go, for a navigate.
    #[serde(default)]
    pub url: Option<String>,
    /// The option to choose in a native dropdown, as its text.
    #[serde(default)]
    pub option: Option<String>,
    /// The node of the page map to act on, by its number, in DOM mode.
    #[serde(default)]
    pub target: Option<u32>,
    /// Where to scroll to, in page pixels from the top, in DOM mode.
    #[serde(default)]
    pub to: Option<f64>,
}

/// A point of a drag's path as the model writes it.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct RawPoint {
    #[serde(default)]
    pub x: Option<f64>,
    #[serde(default)]
    pub y: Option<f64>,
}

/// Reads the model's answer. The answer may carry text before the JSON; it is skipped.
pub fn parse_reply(content: &str) -> Result<Reply, String> {
    parse_json(content)
}

/// Reads a JSON object of any shape from a model's answer, past any text before it.
pub fn parse_json<T: serde::de::DeserializeOwned>(content: &str) -> Result<T, String> {
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
/// of the survey the look was, empty for a plain look. `page` is the map the look carried: an
/// action that names a node of it by number (`target`) gets the node's centre as its point,
/// and a check that names one is bound to the node's role and name (`check.rs`).
pub fn check_actions(step: u32, raw: Vec<RawAction>, vp: &Viewport, max_actions: usize, screens: &[f64], page: Option<&PageMap>) -> (Vec<Action>, Vec<String>) {
    let mut valid = Vec::new();
    let mut dropped = Vec::new();
    for (i, input) in raw.into_iter().enumerate() {
        let n = i + 1;
        if valid.len() >= max_actions {
            dropped.push(format!("action {n} ({}): only {max_actions} actions run per step", input.kind));
            continue;
        }
        let target = match aim(&input, vp, page) {
            Ok(target) => target,
            Err(why) => {
                dropped.push(format!("action {n} ({}): {why}", input.kind));
                continue;
            }
        };
        let kind = match fill(&input, vp, target.as_ref().map(|(_, point)| *point)) {
            Ok(kind) => kind,
            Err(why) => {
                dropped.push(format!("action {n} ({}): {why}", input.kind));
                continue;
            }
        };
        let mut action = Action::new(format!("s{step}a{n}"), kind);
        // A targeted action is placed by the browser, on the node, wherever the page is scrolled.
        if target.is_none()
            && let Err(why) = place_on_screen(&mut action, input.screen, vp, screens)
        {
            dropped.push(format!("action {n} ({}): {why}", input.kind));
            continue;
        }
        action.target = target.map(|(target, _)| target);
        let check = clip_text(input.check.as_deref().unwrap_or("").trim(), MAX_CHECK_CHARS);
        action.check = match page {
            Some(page) => Check::bind(&check, page),
            None => check,
        };
        action.label = clip_text(input.label.as_deref().unwrap_or("").trim(), MAX_LABEL_CHARS);
        action.commit = commit_of(&input, &action.kind);
        valid.push(action);
    }
    (valid, dropped)
}

/// The node an action names on the page map, with the centre of its box in screenshot pixels
/// (which may lie off the screen: the browser scrolls to it). `None` when the action names
/// none; an error when it names one the map does not have.
fn aim(input: &RawAction, vp: &Viewport, page: Option<&PageMap>) -> Result<Option<(Target, Point)>, String> {
    let Some(id) = input.target else { return Ok(None) };
    let Some(page) = page else { return Err(format!("target [{id}] named, but the look carried no page map")) };
    let Some(node) = page.nodes.iter().find(|node| node.id == id) else { return Err(format!("there is no node [{id}] on the page map")) };
    // Text is read, never pressed.
    if node.is_text() && input.kind != "read" {
        return Err(format!("node [{id}] is plain text, not a control"));
    }
    let point = Point { x: node.x + node.w / 2.0 - vp.scroll_x, y: node.y + node.h / 2.0 - vp.scroll_y };
    Ok(Some((Target { id, role: node.role.clone(), name: node.name.clone(), frame: node.frame }, point)))
}

/// The kind an action is, with what it carries, once its fields are checked. `aimed` is the
/// point of the node the action targets, in place of any point the model wrote.
fn fill(input: &RawAction, vp: &Viewport, aimed: Option<Point>) -> Result<Kind, String> {
    let point = |input: &RawAction| -> Result<(f64, f64), String> {
        match aimed {
            Some(p) => Ok((p.x, p.y)),
            None => point(input, vp),
        }
    };
    Ok(match input.kind.as_str() {
        "click" => {
            let (x, y) = point(input)?;
            Kind::Click { x, y, modifiers: modifiers(input)? }
        }
        "double_click" => {
            let (x, y) = point(input)?;
            Kind::DoubleClick { x, y, modifiers: modifiers(input)? }
        }
        "triple_click" => {
            let (x, y) = point(input)?;
            Kind::TripleClick { x, y, modifiers: modifiers(input)? }
        }
        "right_click" => {
            let (x, y) = point(input)?;
            Kind::RightClick { x, y, modifiers: modifiers(input)? }
        }
        "hover" => {
            let (x, y) = point(input)?;
            Kind::Hover { x, y, modifiers: modifiers(input)? }
        }
        "drag" => {
            let raw = input.path.as_deref().unwrap_or(&[]);
            if raw.len() < 2 {
                return Err("a drag needs a path of at least two points".to_string());
            }
            if raw.len() > MAX_PATH_POINTS {
                return Err(format!("the path has more than {MAX_PATH_POINTS} points"));
            }
            let mut path = Vec::with_capacity(raw.len());
            for p in raw {
                match (p.x, p.y) {
                    (Some(x), Some(y)) if inside(x, y, vp) => path.push(Point { x, y }),
                    (Some(x), Some(y)) => return Err(format!("the point ({x:.0}, {y:.0}) lies outside the {}x{} screenshot", vp.width, vp.height)),
                    _ => return Err("a point of the path has no x or y".to_string()),
                }
            }
            Kind::Drag { path, modifiers: modifiers(input)? }
        }
        "upload" => {
            let (x, y) = point(input)?;
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
            // Straight to a height of the page, or to where the target node is, a third of
            // the screen down so what is round it shows too.
            let to = match (input.to, aimed) {
                (Some(to), _) => Some(to.max(0.0).min(vp.page_height.max(0.0))),
                (None, Some(p)) => Some((p.y + vp.scroll_y - vp.height as f64 / 3.0).max(0.0)),
                (None, None) => None,
            };
            if let Some(to) = to {
                return Ok(Kind::Scroll { x: None, y: None, dx: 0.0, dy: 0.0, to: Some(to) });
            }
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
                to: None,
            }
        }
        "read" => {
            if aimed.is_none() {
                return Err("read needs a target node".to_string());
            }
            Kind::Read
        }
        "wait" => Kind::Wait { ms: input.ms.unwrap_or(DEFAULT_WAIT_MS).clamp(MIN_WAIT_MS, MAX_WAIT_MS) },
        "navigate" => {
            let url = input.url.as_deref().unwrap_or("").trim().to_string();
            if url.is_empty() {
                return Err("there is no address to go to".to_string());
            }
            if url.chars().count() > MAX_URL_CHARS {
                return Err("the address is too long".to_string());
            }
            let lower = url.to_ascii_lowercase();
            if !(lower.starts_with("http://") || lower.starts_with("https://") || lower.starts_with("file://")) {
                return Err(format!("{url:?} is not a web address: write it whole, starting with https://"));
            }
            Kind::Navigate { url }
        }
        "choose" => {
            let option = input.option.as_deref().unwrap_or("").trim().to_string();
            if option.is_empty() {
                return Err("there is no option to choose".to_string());
            }
            if option.chars().count() > MAX_LABEL_CHARS {
                return Err(format!("the option is longer than {MAX_LABEL_CHARS} characters"));
            }
            Kind::Choose { option }
        }
        "back" => Kind::Back,
        "survey" => Kind::Survey,
        "resume" => Kind::Resume,
        _ => return Err("that is not an action the harness can send".to_string()),
    })
}

/// The keys held during the action, in one spelling (`Shift+Meta`), or empty for none.
fn modifiers(input: &RawAction) -> Result<String, String> {
    let text = input.modifiers.as_deref().unwrap_or("").trim();
    if text.is_empty() {
        return Ok(String::new());
    }
    let mut held: Vec<&str> = Vec::new();
    for part in text.split('+').map(str::trim).filter(|p| !p.is_empty()) {
        let name = match part.to_ascii_lowercase().as_str() {
            "shift" => "Shift",
            "control" | "ctrl" => "Control",
            "alt" | "option" => "Alt",
            "meta" | "command" | "cmd" => "Meta",
            _ => return Err(format!("{part:?} is not a key that can be held (Shift, Control, Alt, Meta)")),
        };
        if !held.contains(&name) {
            held.push(name);
        }
    }
    Ok(held.join("+"))
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
/// With `dom`, a pointed action names a node by number (`target`) instead of a point, scroll
/// goes to a height or a node, and `read` exists.
pub fn reply_schema(survey: bool, checks: bool, dom: bool) -> Value {
    // DOM mode plans from the map: no survey, no screens, no settled parts, no field list.
    let survey = survey && !dom;
    let string = json!({"type": "string"});
    let null_string = json!({"type": ["string", "null"]});
    let number = json!({"type": "number"});
    let null_number = json!({"type": ["number", "null"]});
    let integer = json!({"type": "integer"});
    let point = |kinds: &[&str], extra: Vec<(&str, Value)>| -> Value {
        let mut fields = vec![("kind", kind_enum(kinds))];
        if survey {
            fields.push(("screen", json!({"type": ["integer", "null"]})));
        }
        if dom {
            fields.push(("target", integer.clone()));
        } else {
            fields.push(("x", number.clone()));
            fields.push(("y", number.clone()));
        }
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
    let held = json!({"anyOf": [{"type": "null"}, {"type": "string", "enum": ["Shift", "Control", "Alt", "Meta", "Shift+Meta", "Shift+Control", "Shift+Alt"]}]});
    let mut drag = vec![("kind", kind_enum(&["drag"]))];
    if survey {
        drag.push(("screen", json!({"type": ["integer", "null"]})));
    }
    drag.push(("path", json!({"type": "array", "items": object(vec![("x", number.clone()), ("y", number.clone())])})));
    drag.push(("label", null_string.clone()));
    drag.push(("modifiers", held.clone()));
    if checks {
        drag.push(("check", null_string.clone()));
    }
    let mut shapes = vec![
        point(&["click", "double_click", "triple_click", "right_click", "hover"], vec![
            ("commit", json!({"anyOf": [{"type": "null"}, {"type": "string", "enum": ["next", "send", "pay", "post", "delete", "create_account"]}]})),
            ("modifiers", held),
        ]),
        object(drag),
        point(&["upload"], vec![("resource", null_string.clone())]),
        plain("type", vec![("text", string.clone()), ("secret", json!({"type": ["boolean", "null"]}))]),
        plain("key", vec![("keys", string.clone())]),
        if dom {
            plain("scroll", vec![("to", null_number.clone()), ("target", json!({"type": ["integer", "null"]})), ("dx", null_number.clone()), ("dy", null_number.clone())])
        } else {
            plain("scroll", vec![("x", null_number.clone()), ("y", null_number.clone()), ("dx", number.clone()), ("dy", number.clone())])
        },
        object(vec![("kind", kind_enum(&["wait"])), ("ms", json!({"type": "integer"}))]),
        plain("navigate", vec![("url", string.clone())]),
        plain("choose", vec![("option", string.clone())]),
        plain("back", vec![]),
        object(vec![("kind", kind_enum(&["resume"]))]),
    ];
    if survey {
        shapes.push(object(vec![("kind", kind_enum(&["survey"]))]));
    }
    if dom {
        shapes.push(plain("read", vec![("target", integer.clone())]));
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
        ("proof", null_string.clone()),
        ("answer", null_string.clone()),
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
            raw(r#"{"kind":"drag","screen":1,"path":[{"x":10,"y":10},{"x":50,"y":60}],"modifiers":"shift+cmd","label":"Brush"}"#),
            raw(r#"{"kind":"drag","path":[{"x":10,"y":10}]}"#),
            raw(r#"{"kind":"click","x":5,"y":5,"modifiers":"Hyper"}"#),
            raw(r#"{"kind":"navigate","url":"https://example.test/a"}"#),
            raw(r#"{"kind":"navigate","url":"example.test"}"#),
            raw(r#"{"kind":"back"}"#),
            raw(r#"{"kind":"choose","option":" United States of America "}"#),
            raw(r#"{"kind":"choose","option":""}"#),
        ];
        let (valid, dropped) = check_actions(3, raw, &vp, 30, &[0.0, 500.0], None);
        let ids: Vec<&str> = valid.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, vec!["s3a1", "s3a3", "s3a4", "s3a6", "s3a8", "s3a11", "s3a13", "s3a14"]);
        assert_eq!(valid[7].kind, Kind::Choose { option: "United States of America".to_string() });
        assert_eq!(valid[5].kind, Kind::Navigate { url: "https://example.test/a".to_string() });
        assert_eq!(valid[6].kind, Kind::Back);
        assert_eq!(valid[4].kind, Kind::Drag { path: vec![Point { x: 10.0, y: 10.0 }, Point { x: 50.0, y: 60.0 }], modifiers: "Shift+Meta".to_string() });
        assert_eq!(valid[4].zone, 1);
        assert_eq!(valid[4].label, "Brush");
        assert_eq!(valid[0].scroll_to, Some(500.0));
        assert_eq!(valid[0].zone, 2);
        assert_eq!(valid[0].commit, Commit::Send);
        assert_eq!(valid[0].label, "Send");
        assert_eq!(valid[1].kind, Kind::Wait { ms: 100 });
        assert_eq!(valid[2].kind, Kind::Scroll { x: Some(400.0), y: Some(300.0), dx: 0.0, dy: 1800.0, to: None });
        assert_eq!(valid[3].kind, Kind::Survey);
        assert_eq!(dropped.len(), 7);
    }

    #[test]
    fn a_target_gives_the_action_its_point_and_binds_its_check_to_the_node() {
        use crate::page::{PageMap, PageNode};
        let vp = Viewport { width: 800, height: 600, scroll_y: 1000.0, page_width: 800.0, page_height: 3000.0, ..Default::default() };
        let page = PageMap {
            nodes: vec![
                PageNode { id: 1, role: "radio".into(), name: "Work".into(), x: 100.0, y: 1200.0, w: 20.0, h: 20.0, ..Default::default() },
                PageNode { id: 2, role: "text".into(), name: "Some words".into(), x: 0.0, y: 0.0, w: 100.0, h: 10.0, ..Default::default() },
                PageNode { id: 3, role: "button".into(), name: "Continue".into(), x: 100.0, y: 2500.0, w: 100.0, h: 40.0, ..Default::default() },
            ],
        };
        let written = vec![
            raw(r#"{"kind":"click","target":1,"check":"[1] checked"}"#),
            raw(r#"{"kind":"click","target":2}"#),
            raw(r#"{"kind":"click","target":9}"#),
            raw(r#"{"kind":"scroll","target":3}"#),
            raw(r#"{"kind":"scroll","to":2400}"#),
            raw(r#"{"kind":"read","target":3}"#),
            raw(r#"{"kind":"read"}"#),
            raw(r#"{"kind":"click","x":5,"y":5,"check":"the list is open"}"#),
            raw(r#"{"kind":"read","target":2}"#),
        ];
        let (valid, dropped) = check_actions(1, written, &vp, 30, &[], Some(&page));
        let ids: Vec<&str> = valid.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, vec!["s1a1", "s1a4", "s1a5", "s1a6", "s1a8", "s1a9"]);
        // Text is read, never pressed: the click on it is refused, the read of it is not.
        assert_eq!(valid[5].kind, Kind::Read);
        assert_eq!(valid[5].target.as_ref().map(|t| (t.id, t.role.as_str())), Some((2, "text")));
        // The point is the node's centre in screenshot pixels, off screen or not.
        assert_eq!(valid[0].kind, Kind::Click { x: 110.0, y: 210.0, modifiers: String::new() });
        assert_eq!(valid[0].target, Some(Target { id: 1, role: "radio".into(), name: "Work".into(), frame: 0 }));
        assert_eq!(valid[0].check, "[radio \"Work\"] checked");
        assert!(valid[0].scroll_to.is_none());
        assert_eq!(valid[1].kind, Kind::Scroll { x: None, y: None, dx: 0.0, dy: 0.0, to: Some(2320.0) });
        assert_eq!(valid[2].kind, Kind::Scroll { x: None, y: None, dx: 0.0, dy: 0.0, to: Some(2400.0) });
        assert_eq!(valid[3].kind, Kind::Read);
        assert_eq!(valid[3].target.as_ref().map(|t| t.id), Some(3));
        assert_eq!(valid[4].check, "the list is open");
        assert_eq!(dropped.len(), 3);
        assert!(dropped[0].contains("plain text"), "{}", dropped[0]);
        assert!(dropped[1].contains("no node [9]"), "{}", dropped[1]);
        assert!(dropped[2].contains("needs a target"), "{}", dropped[2]);
        // Without a map, a target is refused rather than guessed.
        let (valid, dropped) = check_actions(1, vec![raw(r#"{"kind":"click","target":1}"#)], &vp, 30, &[], None);
        assert!(valid.is_empty() && dropped[0].contains("no page map"), "{dropped:?}");
    }

    #[test]
    fn the_reply_is_read_past_leading_text_and_the_schema_keeps_its_order() {
        let reply = parse_reply("Sure. {\"status\":\"working\",\"message\":\"\",\"actions\":[{\"kind\":\"wait\",\"ms\":100}]}").unwrap();
        assert_eq!(reply.status, Status::Working);
        assert_eq!(reply.actions[0].kind, "wait");
        assert!(parse_reply("").is_err());
        let reply = parse_reply("{\"status\":\"done\",\"message\":\"\",\"proof\":\"the row shows 25 kg\",\"answer\":\"Economy Classic: 25 kg\",\"actions\":[]}").unwrap();
        assert_eq!(reply.proof.as_deref(), Some("the row shows 25 kg"));
        assert_eq!(reply.answer.as_deref(), Some("Economy Classic: 25 kg"));
        let schema = reply_schema(true, true, false).to_string();
        assert!(schema.find("\"observation\"").unwrap() < schema.find("\"actions\"").unwrap());
        assert!(schema.contains("\"proof\""));
        assert!(schema.contains("\"answer\""));
        assert!(schema.contains("\"choose\""));
        assert!(schema.contains("\"survey\""));
        assert!(schema.contains("\"needs_person\""));
        let plain = reply_schema(false, false, false).to_string();
        assert!(!plain.contains("\"check\"") && !plain.contains("\"fields\""));
        let dom = reply_schema(true, true, true).to_string();
        assert!(dom.contains("\"target\"") && dom.contains("\"read\"") && dom.contains("\"to\"") && !dom.contains("\"survey\"") && !dom.contains("\"screen\""), "{dom}");
    }
}
