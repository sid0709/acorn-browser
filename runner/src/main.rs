//! Runs one task from a Markdown file against the Acorn Browser app: the harness decides, the
//! app looks and does (over its agent socket), OpenRouter answers.
//!
//! ```text
//! acorn-runner <task.md>
//!   --socket <path>          the app's agent socket (default: in the app's data folder)
//!   --model <id>             the driving model (default openai/gpt-6-luna)
//!   --decider <id> | none    the decision model on a Decisions API (default openai/gpt-6-luna-decisions)
//!   --decisions openrouter | openai
//!   --reasoning <effort>     none, low, medium or high for the driving model (default none)
//!   --mode image | dom       how the model sees the page (default image; a `mode:` line in the task wins)
//!   --profile <file>         who the run acts as (default: profile.md in the app's data folder)
//!   --trace <dir>            where to write the run's trace (default: traces/ in the current folder)
//!   --env-file <file>        a file of KEY=VALUE lines to read the keys from
//! ```
//!
//! The task file is the kit's: `key: value` lines between `---` markers, then the goal; a file
//! with no markers is all goal. Without a `url:` line the run starts on the page the browser shows.
//!
//! The keys are read from the environment, then from `--env-file`, then from `.env` in the app's
//! data folder, then from `.env` beside this crate.
//!
//! Output is one JSON object per line on stdout, for the app to show (`start`, `step`,
//! `action_failed`, `end`, `error`); anything else goes to stderr. Exit code 0 when the task is
//! done, 1 when the run stopped for the person or got stuck, 2 when something failed.

mod browser;
mod decide;
mod taskfile;

use std::path::PathBuf;
use std::process::exit;
use std::time::Instant;

use harness::action::{Action, Kind};
use harness::intake;
use harness::openrouter::{OpenRouter, UreqTransport};
use harness::ports::Browser;
use harness::profile::Profile;
use harness::run::{Agent, Config, Status, Step};
use serde_json::{Value, json};

use crate::browser::AppBrowser;
use crate::decide::{Decisions, Meter, Metered, Tally, Wire};

const OPENROUTER_URL: &str = "https://openrouter.ai/api/v1";
const DEFAULT_MODEL: &str = "openai/gpt-6-luna";
const DEFAULT_REASONING: &str = "none";
/// The facts the run acts on when no profile file is given or found.
const DEFAULT_FACTS: &str = "The person gave no details about themselves.";
const APP_ID: &str = "com.acorn.browser";

struct Options {
    task: PathBuf,
    socket: PathBuf,
    model: String,
    decider: Option<String>,
    decisions: Wire,
    reasoning: String,
    mode: Option<harness::task::Mode>,
    profile: PathBuf,
    trace: PathBuf,
    env_file: Option<PathBuf>,
}

/// The app's data folder, where its socket and settings live.
fn app_dir() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    home.join("Library/Application Support").join(APP_ID)
}

fn options() -> Result<Options, String> {
    let mut args = std::env::args().skip(1);
    let mut out = Options {
        task: PathBuf::new(),
        socket: std::env::var_os("ACORN_AGENT_SOCKET").map(PathBuf::from).unwrap_or_else(|| app_dir().join("agent.sock")),
        model: DEFAULT_MODEL.to_string(),
        decider: None,
        decisions: Wire::OpenRouter,
        reasoning: DEFAULT_REASONING.to_string(),
        mode: None,
        profile: app_dir().join("profile.md"),
        trace: PathBuf::from("traces"),
        env_file: None,
    };
    let mut decider_named = false;
    while let Some(arg) = args.next() {
        let mut value = |name: &str| args.next().ok_or_else(|| format!("{name} needs a value"));
        match arg.as_str() {
            "--socket" => out.socket = PathBuf::from(value("--socket")?),
            "--model" => out.model = value("--model")?,
            "--decider" => {
                let named = value("--decider")?;
                decider_named = true;
                out.decider = if named == "none" { None } else { Some(named) };
            }
            "--decisions" => {
                out.decisions = match value("--decisions")?.as_str() {
                    "openrouter" => Wire::OpenRouter,
                    "openai" => Wire::OpenAI,
                    other => return Err(format!("--decisions is openrouter or openai, not {other:?}")),
                }
            }
            "--reasoning" => out.reasoning = value("--reasoning")?,
            "--mode" => out.mode = Some(taskfile::mode_of(&value("--mode")?)?),
            "--profile" => out.profile = PathBuf::from(value("--profile")?),
            "--trace" => out.trace = PathBuf::from(value("--trace")?),
            "--env-file" => out.env_file = Some(PathBuf::from(value("--env-file")?)),
            "--help" | "-h" => return Err(USAGE.to_string()),
            other if other.starts_with("--") => return Err(format!("unknown option {other}\n{USAGE}")),
            other => out.task = PathBuf::from(other),
        }
    }
    if out.task.as_os_str().is_empty() {
        return Err(USAGE.to_string());
    }
    if !decider_named {
        out.decider = Some(match out.decisions {
            Wire::OpenRouter => decide::OPENROUTER_DECISION_MODEL,
            Wire::OpenAI => decide::OPENAI_DECISION_MODEL,
        }.to_string());
    }
    Ok(out)
}

const USAGE: &str = "usage: acorn-runner <task.md> [--socket <path>] [--model <id>] [--decider <id>|none] [--decisions openrouter|openai] [--reasoning <effort>] [--mode image|dom] [--profile <file>] [--trace <dir>] [--env-file <file>]";

/// Prints one event for the app.
fn emit(event: Value) {
    println!("{event}");
}

fn main() {
    match run() {
        Ok(code) => exit(code),
        Err(message) => {
            emit(json!({"event": "error", "message": message}));
            eprintln!("{message}");
            exit(2);
        }
    }
}

/// Reads `KEY=VALUE` lines from a file into the environment, for the keys not set already.
/// Comments and blank lines are skipped; quotes round a value are dropped.
fn load_dotenv(path: &std::path::Path) {
    let Ok(text) = std::fs::read_to_string(path) else { return };
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else { continue };
        let key = key.trim().trim_start_matches("export ").trim();
        let value = value.trim().trim_matches('"').trim_matches('\'');
        if !key.is_empty() && std::env::var_os(key).is_none() {
            // Set before any thread starts: the runner is single-threaded here.
            unsafe { std::env::set_var(key, value) };
        }
    }
}

fn status_name(status: Status) -> String {
    serde_json::to_value(status).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default()
}

fn run() -> Result<i32, String> {
    // The clock runs from here: everything the person waits for counts, the reading of the
    // request and the opening of the site included.
    let started = Instant::now();
    let options = options()?;
    if let Some(file) = &options.env_file {
        load_dotenv(file);
    }
    load_dotenv(&app_dir().join(".env"));
    load_dotenv(&PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(".env"));
    let key = std::env::var("OPENROUTER_API_KEY").ok().filter(|k| !k.trim().is_empty()).ok_or_else(|| {
        format!(
            "No OpenRouter key found. Put OPENROUTER_API_KEY=... in {} (the app reads that file).",
            app_dir().join(".env").display()
        )
    })?;

    let mut loaded = taskfile::load(&options.task)?;
    if let Some(mode) = options.mode
        && loaded.task.mode == harness::task::Mode::Image
    {
        loaded.task.mode = mode;
    }
    let facts = std::fs::read_to_string(&options.profile).unwrap_or_else(|_| DEFAULT_FACTS.to_string());

    let model_meter = Meter::default();
    let check_meter = Meter::default();
    let model = Metered { inner: OpenRouter::new(key.clone(), options.model.clone(), OPENROUTER_URL, options.reasoning.clone(), Box::new(UreqTransport::default())), meter: model_meter.clone() };

    // A request in plain words names neither where to start nor what "done" looks like: the
    // model reads them from it before the run, and the person sees what it understood.
    if intake::needed(&loaded.task) {
        let sheet = intake::understand(&model, &loaded.task.goal, &Profile::new(facts.clone())).map_err(|e| format!("The request could not be understood: {e}"))?;
        intake::apply(&sheet, &mut loaded.task);
        emit(json!({
            "event": "understood", "summary": sheet.summary, "startUrl": loaded.task.start_url,
            "doneWhen": loaded.task.done_when, "approach": loaded.task.approach, "watchOut": loaded.task.watch_out, "relentless": sheet.relentless,
        }));
    }
    let mut agent = Agent::new(Config::default(), Box::new(model)).with_trace_dir(&options.trace);
    if let Some(decider) = &options.decider {
        let (decision_key, url) = match options.decisions {
            Wire::OpenRouter => (key.clone(), decide::OPENROUTER_DECISIONS_URL),
            Wire::OpenAI => (std::env::var("OPENAI_API_KEY").ok().filter(|k| !k.trim().is_empty()).ok_or("set OPENAI_API_KEY for OpenAI's Decisions API")?, decide::OPENAI_DECISIONS_URL),
        };
        let mut checker = Decisions::new(&decision_key, decider, url, options.decisions);
        checker.meter = check_meter.clone();
        agent = agent.with_decider(Box::new(checker));
    }

    let mut browser = AppBrowser::connect(&options.socket).map_err(|e| e.to_string())?.with_resources(loaded.files);
    if let Some(url) = &loaded.task.start_url {
        browser.open(url).map_err(|e| e.to_string())?;
    }

    let max_steps = loaded.task.persistence.max_steps;
    let mode_name = serde_json::to_value(loaded.task.mode).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default();
    let goal_line = loaded.task.goal.lines().next().unwrap_or("").to_string();
    let start_url = loaded.task.start_url.clone();
    let id = agent.start(loaded.task, Profile::new(facts));
    emit(json!({
        "event": "start", "run": id, "goal": goal_line, "startUrl": start_url, "model": options.model, "mode": mode_name,
        "checker": options.decider, "maxSteps": max_steps, "trace": options.trace.join(&id).display().to_string(),
    }));

    let mut results = Vec::new();
    let mut survey = false;
    let last = loop {
        let mut obs = browser.observe(survey).map_err(|e| format!("The browser could not look at the page: {e}"))?;
        obs.results = std::mem::take(&mut results);
        let step = agent.step(&id, obs).map_err(|e| format!("The step failed: {e}"))?;
        emit(step_event(&step, started.elapsed().as_secs_f64()));
        if step.status != Status::Working {
            break step;
        }
        results = browser.act(&step.actions).map_err(|e| format!("The browser could not act: {e}"))?;
        for result in results.iter().filter(|r| !r.ok) {
            emit(json!({"event": "action_failed", "id": result.id, "error": result.error}));
        }
        survey = step.survey;
        browser.after(&step);
    };
    emit(end_event(&last, started.elapsed().as_secs_f64(), model_meter.read(), check_meter.read()));
    Ok(if last.status == Status::Done { 0 } else { 1 })
}

/// What one step decided, for the app.
fn step_event(step: &Step, elapsed: f64) -> Value {
    json!({
        "event": "step",
        "number": step.number,
        "status": status_name(step.status),
        "message": step.message,
        "actions": step.actions.iter().map(describe).collect::<Vec<_>>(),
        "dropped": step.dropped,
        "questions": step.questions.iter().map(|q| json!({"id": q.id, "text": q.text})).collect::<Vec<_>>(),
        "seconds": elapsed,
    })
}

fn describe(action: &Action) -> String {
    let label = if action.label.is_empty() { String::new() } else { format!(" {:?}", action.label) };
    match &action.kind {
        Kind::Type { text, secret: true } => format!("type [{} secret characters]", text.chars().count()),
        Kind::Type { text, .. } => format!("type {text:?}"),
        Kind::Key { keys } => format!("press {keys}"),
        Kind::Scroll { to: Some(to), .. } => format!("scroll to {to:.0}"),
        Kind::Scroll { dy, .. } => format!("scroll {dy:+.0}"),
        Kind::Wait { ms } => format!("wait {ms}ms"),
        Kind::Navigate { url } => format!("go to {url}"),
        Kind::Choose { option } => format!("choose {option:?}"),
        Kind::Back => "go back".to_string(),
        Kind::Read => format!("read{label}"),
        Kind::Survey => "look over the whole page".to_string(),
        other => {
            let name = serde_json::to_value(other).ok().and_then(|v| v["kind"].as_str().map(str::to_string)).unwrap_or_default().replace('_', " ");
            match other.point() {
                Some(p) => format!("{name} at ({:.0}, {:.0}){label}", p.x, p.y),
                None => name,
            }
        }
    }
}

/// The end of the run, for the app: the outcome, the report, and what it cost.
fn end_event(last: &Step, elapsed: f64, model: Tally, checks: Tally) -> Value {
    // The time spent waiting on the models, apart: what is left is the browser's and the
    // harness's own, which a change to them is judged by whatever the provider's mood.
    let mut event = json!({
        "event": "end",
        "status": status_name(last.status),
        "message": last.message,
        "seconds": elapsed,
        "modelSeconds": (model.waited + checks.waited).as_secs_f64(),
        "modelCalls": model.calls + checks.calls,
        "cost": model.usage.cost + checks.usage.cost,
    });
    if let Some(answer) = &last.answer {
        event["answer"] = json!(answer);
    }
    if let Some(stop) = &last.stop {
        event["stop"] = json!({"problem": stop.problem, "action": stop.action});
    }
    if let Some(report) = &last.report {
        event["report"] = json!({
            "assumed": report.assumed,
            "left": report.left.iter().map(|f| f.label.clone()).collect::<Vec<_>>(),
            "questions": report.questions.iter().map(|q| json!({"text": q.text, "answer": q.answer})).collect::<Vec<_>>(),
            "steps": report.steps,
        });
    }
    event
}
