//! Turning a request in plain words into the sheet a run works from, before the run starts.
//!
//! A task file names where to start and what "done" looks like; a person typing in chat names
//! neither. Without them the run begins on whatever page the browser shows and, with no address
//! to go to, stays there. So the driving model is asked once, with no screenshot, to read the
//! request as a careful assistant would: the site it means, what the screen will show when it
//! is done, how to go about it and what to watch out for, what the request itself permits among
//! the actions that cannot be taken back, and how hard to push. The goal stays in the person's
//! own words; the sheet only fills in what the task was not given.
//!
//! The approach is where the thinking happens before the run: a driving model without reasoning
//! of its own takes the first good-looking answer (a recorded run opened the first thread with a
//! big count on an unsorted list, when the task asked for the one with the most replies). A few
//! conditional lines written from the request alone ("if a sort control is in view, sort by it
//! first") steer it, while invented addresses and button names would mislead it, so the sheet is
//! asked for the one and told to leave out the other.

use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::{Value, json};

use crate::model::parse_json;
use crate::ports::{Error, ErrorKind, Message, Model, ModelRequest, Role, Usage};
use crate::profile::Profile;
use crate::prompt::render;
use crate::task::{Allowance, Irreversible, Persistence, Task};

const INTAKE_TEMPLATE: &str = include_str!("prompts/intake.md");

/// What the model read from the request.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Sheet {
    pub start_url: Option<String>,
    pub done_when: String,
    /// How to go about the task, in a few conditional lines, and what to watch out for.
    pub approach: Vec<String>,
    pub watch_out: Vec<String>,
    pub allowances: BTreeMap<Irreversible, Allowance>,
    pub relentless: bool,
    /// One line for the person: what will be done and where.
    pub summary: String,
    pub usage: Usage,
}

#[derive(Deserialize)]
struct RawSheet {
    #[serde(default)]
    start_url: Option<String>,
    #[serde(default)]
    done_when: String,
    #[serde(default)]
    approach: Vec<String>,
    #[serde(default)]
    watch_out: Vec<String>,
    #[serde(default)]
    allow: BTreeMap<String, String>,
    #[serde(default)]
    relentless: bool,
    #[serde(default)]
    summary: String,
}

/// Asks the model for the sheet of a request.
pub fn understand(model: &dyn Model, request: &str, profile: &Profile) -> Result<Sheet, Error> {
    let mut values: BTreeMap<&str, String> = BTreeMap::new();
    values.insert("request", request.trim().to_string());
    values.insert("profile", profile.facts.trim().to_string());
    let response = model.complete(ModelRequest {
        messages: vec![Message { role: Role::User, text: render(INTAKE_TEMPLATE, &values), images: vec![], cache: false }],
        schema_name: "task_sheet".to_string(),
        schema: schema(),
    })?;
    let raw: RawSheet = parse_json(&response.content).map_err(|why| Error::new(ErrorKind::Server, format!("the task sheet could not be read: {why}")))?;
    Ok(Sheet {
        start_url: raw.start_url.map(|u| u.trim().to_string()).filter(|u| is_address(u)),
        done_when: raw.done_when.trim().to_string(),
        approach: lines(raw.approach, MAX_APPROACH_LINES),
        watch_out: lines(raw.watch_out, MAX_WATCH_OUT_LINES),
        allowances: raw.allow.iter().filter_map(|(kind, allowance)| Some((kind_of(kind)?, allowance_of(allowance)?))).collect(),
        relentless: raw.relentless,
        summary: raw.summary.trim().to_string(),
        usage: response.usage,
    })
}

/// Fills in what the task was not given: a start address, what "done" looks like, the
/// allowances of kinds not set, and the persistence. What the task already has stays.
pub fn apply(sheet: &Sheet, task: &mut Task) {
    if task.start_url.is_none() {
        task.start_url = sheet.start_url.clone();
    }
    if task.done_when.trim().is_empty() {
        task.done_when = sheet.done_when.clone();
    }
    if task.approach.is_empty() {
        task.approach = sheet.approach.clone();
    }
    if task.watch_out.is_empty() {
        task.watch_out = sheet.watch_out.clone();
    }
    for (kind, allowance) in &sheet.allowances {
        task.allowances.entry(*kind).or_insert(*allowance);
    }
    if sheet.relentless && task.persistence.stop_for == Persistence::default().stop_for {
        let steps = task.persistence.max_steps;
        task.persistence = Persistence::relentless();
        task.persistence.max_steps = steps;
    }
}

/// Whether a task needs the sheet: it was given no address, no "done", or no approach.
pub fn needed(task: &Task) -> bool {
    task.start_url.is_none() || task.done_when.trim().is_empty() || task.approach.is_empty()
}

/// The most lines of approach, and of things to watch out for, the sheet keeps: a model with no
/// reasoning of its own follows the first few rules best.
const MAX_APPROACH_LINES: usize = 6;
const MAX_WATCH_OUT_LINES: usize = 4;
/// The most characters one such line keeps.
const MAX_LINE_CHARS: usize = 240;

/// The lines trimmed, the empty ones dropped, each cut to a sentence or two, at most `max`.
fn lines(raw: Vec<String>, max: usize) -> Vec<String> {
    raw.iter().map(|line| line.trim()).filter(|line| !line.is_empty()).map(|line| crate::model::clip_text(line, MAX_LINE_CHARS)).take(max).collect()
}

fn is_address(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    lower.starts_with("https://") || lower.starts_with("http://")
}

fn kind_of(name: &str) -> Option<Irreversible> {
    Some(match name.trim() {
        "send" => Irreversible::Send,
        "pay" => Irreversible::Pay,
        "post" => Irreversible::Post,
        "delete" => Irreversible::Delete,
        "create_account" => Irreversible::CreateAccount,
        _ => return None,
    })
}

fn allowance_of(name: &str) -> Option<Allowance> {
    Some(match name.trim() {
        "auto" => Allowance::Auto,
        "ask" => Allowance::Ask,
        "never" => Allowance::Never,
        _ => return None,
    })
}

/// The strict schema of the sheet.
fn schema() -> Value {
    let allowance = json!({"type": "string", "enum": ["auto", "ask", "never"]});
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["start_url", "done_when", "approach", "watch_out", "allow", "relentless", "summary"],
        "properties": {
            "start_url": {"type": ["string", "null"]},
            "done_when": {"type": "string"},
            "approach": {"type": "array", "items": {"type": "string"}},
            "watch_out": {"type": "array", "items": {"type": "string"}},
            "allow": {
                "type": "object",
                "additionalProperties": false,
                "required": ["send", "pay", "post", "delete", "create_account"],
                "properties": {
                    "send": allowance, "pay": allowance, "post": allowance, "delete": allowance, "create_account": allowance
                }
            },
            "relentless": {"type": "boolean"},
            "summary": {"type": "string"}
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ports::ModelResponse;

    struct Fixed(&'static str);

    impl Model for Fixed {
        fn complete(&self, request: ModelRequest) -> Result<ModelResponse, Error> {
            assert!(request.messages[0].text.contains("draw a flowchart"));
            assert_eq!(request.schema_name, "task_sheet");
            Ok(ModelResponse { content: self.0.to_string(), ..Default::default() })
        }
        fn name(&self) -> &str {
            "fixed"
        }
    }

    #[test]
    fn a_request_becomes_a_sheet_that_fills_what_the_task_lacks() {
        let model = Fixed(r#"{"start_url":"https://excalidraw.com","done_when":"the canvas shows a flowchart","approach":["If a shape tool is in view, pick the rectangle first.","  ","Join the boxes with the arrow tool."],"watch_out":["A library panel may cover the canvas; close it."],"allow":{"send":"ask","pay":"never","post":"auto","delete":"ask","create_account":"ask"},"relentless":true,"summary":"Draw a flowchart in Excalidraw"}"#);
        let sheet = understand(&model, "draw a flowchart of a login flow in excalidraw", &Profile::new("")).unwrap();
        assert_eq!(sheet.start_url.as_deref(), Some("https://excalidraw.com"));
        assert_eq!(sheet.allowances.get(&Irreversible::Post), Some(&Allowance::Auto));
        assert!(sheet.relentless);

        let mut task = Task::new("draw a flowchart of a login flow in excalidraw").allow(Irreversible::Post, Allowance::Never);
        assert!(needed(&task));
        apply(&sheet, &mut task);
        assert_eq!(task.start_url.as_deref(), Some("https://excalidraw.com"));
        assert_eq!(task.done_when, "the canvas shows a flowchart");
        // The approach keeps its lines in order, without the blank one.
        assert_eq!(task.approach, vec!["If a shape tool is in view, pick the rectangle first.", "Join the boxes with the arrow tool."]);
        assert_eq!(task.watch_out, vec!["A library panel may cover the canvas; close it."]);
        // What the task was given stays.
        assert_eq!(task.allowance(Irreversible::Post), Allowance::Never);
        assert_eq!(task.allowance(Irreversible::Pay), Allowance::Never);
        assert_eq!(task.persistence.stop_for, Persistence::relentless().stop_for);
        assert!(!needed(&task));
    }

    #[test]
    fn an_address_that_is_not_one_is_dropped() {
        let model = Fixed(r#"{"start_url":"excalidraw","done_when":"","allow":{},"relentless":false,"summary":""}"#);
        let sheet = understand(&model, "draw a flowchart", &Profile::new("")).unwrap();
        assert_eq!(sheet.start_url, None);
        let bad = Fixed("not json");
        assert!(understand(&bad, "draw a flowchart", &Profile::new("")).is_err());
    }
}
