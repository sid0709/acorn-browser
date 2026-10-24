//! A task as a Markdown file: a few `key: value` lines between `---` markers, then the goal in
//! the person's words.
//!
//! ```text
//! ---
//! url: https://example.test/form
//! done_when: the page says the order was received
//! allow: send, pay=never
//! steps: 40
//! survey: no
//! mode: dom
//! persistence: relentless
//! resource: cv = files/cv.pdf | My résumé
//! ---
//! Fill the form and place the order.
//! ```
//!
//! `url` may be a path relative to the file, for a local page. `allow` lists the kinds of action
//! the run may do on its own (send, pay, post, delete, create_account), each optionally with
//! `=ask` or `=never`; a kind not listed is asked about. `persistence` is `default` or
//! `relentless`. A `resource` line names a file the task may upload, by the id the model uses.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use harness::task::{Allowance, Irreversible, Mode, Persistence, Resource, Task};

/// A task read from its file, with the files it may upload by id.
pub struct Loaded {
    pub task: Task,
    pub files: HashMap<String, PathBuf>,
}

/// How the model sees the page: `image` (the default), `dom`, or `hybrid` (the map, and a
/// picture when a signal asks for one).
pub fn mode_of(value: &str) -> Result<Mode, String> {
    match value.trim().to_lowercase().as_str() {
        "image" | "" => Ok(Mode::Image),
        "dom" => Ok(Mode::Dom),
        "hybrid" => Ok(Mode::Hybrid),
        other => Err(format!("mode is image, dom or hybrid, not {other:?}")),
    }
}

/// Reads a task file.
pub fn load(path: &Path) -> Result<Loaded, String> {
    let text = fs::read_to_string(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let dir = path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let (header, body) = split(&text);
    let mut task = Task::new(body.trim());
    let mut files = HashMap::new();
    let mut steps = None;
    for (key, value) in header {
        match key.as_str() {
            "url" => task.start_url = Some(if value.contains("://") { value } else { file_url(&dir.join(&value))? }),
            "done_when" => task.done_when = value,
            "approach" => task.approach.push(value),
            "watch_out" => task.watch_out.push(value),
            "steps" => steps = Some(value.parse::<u32>().map_err(|_| format!("steps must be a number, not {value:?}"))?),
            "survey" => task.survey = matches!(value.to_lowercase().as_str(), "yes" | "true" | "on"),
            "mode" => task.mode = mode_of(&value)?,
            "persistence" => match value.to_lowercase().as_str() {
                "relentless" => task.persistence = Persistence::relentless(),
                "default" => task.persistence = Persistence::default(),
                other => return Err(format!("persistence is default or relentless, not {other:?}")),
            },
            "allow" => {
                for part in value.split(',').map(str::trim).filter(|p| !p.is_empty()) {
                    let (kind, allowance) = part.split_once('=').map(|(k, a)| (k.trim(), a.trim())).unwrap_or((part, "auto"));
                    task = task.allow(kind_of(kind)?, allowance_of(allowance)?);
                }
            }
            "resource" => {
                let (id, rest) = value.split_once('=').ok_or_else(|| format!("a resource is `id = path | description`, not {value:?}"))?;
                let (file, description) = rest.split_once('|').unwrap_or((rest, ""));
                let file = dir.join(file.trim());
                let bytes = fs::read(&file).map_err(|e| format!("cannot read the resource {}: {e}", file.display()))?;
                let name = file.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                task.resources.push(Resource { id: id.trim().to_string(), media_type: media_type(&name).to_string(), name, description: description.trim().to_string(), bytes });
                files.insert(id.trim().to_string(), file);
            }
            other => return Err(format!("unknown key {other:?} in {}", path.display())),
        }
    }
    if let Some(steps) = steps {
        task.persistence.max_steps = steps;
    }
    if task.goal.is_empty() {
        return Err(format!("{} has no goal: write it after the --- block", path.display()));
    }
    Ok(Loaded { task, files })
}

/// The header lines as pairs, and the body, of a file that starts with a `---` block; a file
/// without one is all body.
fn split(text: &str) -> (Vec<(String, String)>, String) {
    let mut lines = text.lines();
    if lines.next().map(str::trim) != Some("---") {
        return (Vec::new(), text.to_string());
    }
    let mut header = Vec::new();
    let mut body = Vec::new();
    let mut in_header = true;
    for line in lines {
        if in_header {
            if line.trim() == "---" {
                in_header = false;
                continue;
            }
            if let Some((key, value)) = line.split_once(':') {
                header.push((key.trim().to_lowercase(), value.trim().to_string()));
            }
            continue;
        }
        body.push(line);
    }
    (header, body.join("\n"))
}

fn kind_of(name: &str) -> Result<Irreversible, String> {
    Ok(match name.to_lowercase().as_str() {
        "send" => Irreversible::Send,
        "pay" => Irreversible::Pay,
        "post" => Irreversible::Post,
        "delete" => Irreversible::Delete,
        "create_account" => Irreversible::CreateAccount,
        other => return Err(format!("allow names send, pay, post, delete or create_account, not {other:?}")),
    })
}

fn allowance_of(name: &str) -> Result<Allowance, String> {
    Ok(match name.to_lowercase().as_str() {
        "auto" | "yes" => Allowance::Auto,
        "ask" => Allowance::Ask,
        "never" | "no" => Allowance::Never,
        other => return Err(format!("an allowance is auto, ask or never, not {other:?}")),
    })
}

fn media_type(name: &str) -> &'static str {
    match name.rsplit('.').next().map(|e| e.to_lowercase()).as_deref() {
        Some("pdf") => "application/pdf",
        Some("png") => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("txt") | Some("md") => "text/plain",
        _ => "application/octet-stream",
    }
}

/// A `file://` URL for a local page.
fn file_url(path: &Path) -> Result<String, String> {
    let absolute = fs::canonicalize(path).map_err(|e| format!("cannot find the page {}: {e}", path.display()))?;
    Ok(format!("file://{}", absolute.display()))
}
