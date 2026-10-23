//! Runs one task from a Markdown file against a real browser: the harness decides, Playwright
//! looks and does, OpenRouter answers.
//!
//! ```text
//! OPENROUTER_API_KEY=... cargo run -- tasks/local-form.md
//!   --headed                 show the browser window
//!   --model <id>             the driving model (default openai/gpt-6-luna)
//!   --decider <id> | none    the decision model (default: the driving model; none turns checks off)
//!   --reasoning <effort>     none, low, medium or high for the driving model (default low)
//!   --profile <file>         who the run acts as (default profile.md beside this crate)
//!   --trace <dir>            where to write the run's trace (default traces/ beside this crate)
//!   --viewport <WxH>         the window size (default 1280x720)
//! ```
//!
//! The key may also sit in a `.env` file beside this crate (`OPENROUTER_API_KEY=sk-or-...`); a
//! variable already set in the environment wins.
//!
//! Exit code 0 when the task is done, 1 when the run stopped for the person or got stuck, 2 when
//! something failed.

mod browser;
mod decide;
mod taskfile;

use std::path::PathBuf;
use std::process::exit;

use harness::action::Kind;
use harness::openrouter::{OpenRouter, UreqTransport};
use harness::ports::Browser;
use harness::profile::Profile;
use harness::run::{Agent, Config, Status, Step};
use harness::task::Task;

use crate::browser::Playwright;
use crate::decide::OpenRouterDecider;

const OPENROUTER_URL: &str = "https://openrouter.ai/api/v1";
const DEFAULT_MODEL: &str = "openai/gpt-6-luna";
const DEFAULT_REASONING: &str = "low";
const DEFAULT_VIEWPORT: (u32, u32) = (1280, 720);
/// The facts the run acts on when no profile file is given or found.
const DEFAULT_FACTS: &str = "The person gave no details about themselves.";

struct Options {
    task: PathBuf,
    headed: bool,
    model: String,
    decider: Option<String>,
    reasoning: String,
    profile: PathBuf,
    trace: PathBuf,
    viewport: (u32, u32),
}

fn kit_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn options() -> Result<Options, String> {
    let mut args = std::env::args().skip(1);
    let mut out = Options {
        task: PathBuf::new(),
        headed: false,
        model: DEFAULT_MODEL.to_string(),
        decider: None,
        reasoning: DEFAULT_REASONING.to_string(),
        profile: kit_dir().join("profile.md"),
        trace: kit_dir().join("traces"),
        viewport: DEFAULT_VIEWPORT,
    };
    let mut decider_named = false;
    while let Some(arg) = args.next() {
        let mut value = |name: &str| args.next().ok_or_else(|| format!("{name} needs a value"));
        match arg.as_str() {
            "--headed" => out.headed = true,
            "--model" => out.model = value("--model")?,
            "--decider" => {
                let named = value("--decider")?;
                decider_named = true;
                out.decider = if named == "none" { None } else { Some(named) };
            }
            "--reasoning" => out.reasoning = value("--reasoning")?,
            "--profile" => out.profile = PathBuf::from(value("--profile")?),
            "--trace" => out.trace = PathBuf::from(value("--trace")?),
            "--viewport" => {
                let size = value("--viewport")?;
                let (w, h) = size.split_once('x').ok_or_else(|| format!("--viewport is WxH, not {size:?}"))?;
                out.viewport = (w.parse().map_err(|_| "bad width".to_string())?, h.parse().map_err(|_| "bad height".to_string())?);
            }
            "--help" | "-h" => return Err(USAGE.to_string()),
            other if other.starts_with("--") => return Err(format!("unknown option {other}\n{USAGE}")),
            other => out.task = PathBuf::from(other),
        }
    }
    if out.task.as_os_str().is_empty() {
        return Err(USAGE.to_string());
    }
    if !decider_named {
        out.decider = Some(out.model.clone());
    }
    Ok(out)
}

const USAGE: &str = "usage: harness-kit <task.md> [--headed] [--model <id>] [--decider <id>|none] [--reasoning <effort>] [--profile <file>] [--trace <dir>] [--viewport <WxH>]";

fn main() {
    match run() {
        Ok(code) => exit(code),
        Err(message) => {
            eprintln!("{message}");
            exit(2);
        }
    }
}

/// Reads `KEY=VALUE` lines from `.env` beside this crate into the environment, for the keys not
/// set already. Comments and blank lines are skipped; quotes round a value are dropped.
fn load_dotenv() {
    let Ok(text) = std::fs::read_to_string(kit_dir().join(".env")) else { return };
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

fn run() -> Result<i32, String> {
    let options = options()?;
    load_dotenv();
    let key = std::env::var("OPENROUTER_API_KEY")
        .ok()
        .filter(|k| !k.trim().is_empty())
        .ok_or("set OPENROUTER_API_KEY in the environment or in kit/.env (see .env.example)")?;
    let loaded = taskfile::load(&options.task)?;
    let facts = std::fs::read_to_string(&options.profile).unwrap_or_else(|_| DEFAULT_FACTS.to_string());
    let start_url = loaded.task.start_url.clone().ok_or("the task file needs a url: line")?;

    let model = OpenRouter::new(key.clone(), options.model.clone(), OPENROUTER_URL, options.reasoning.clone(), Box::new(UreqTransport::default()));
    let mut agent = Agent::new(Config::default(), Box::new(model)).with_trace_dir(&options.trace);
    if let Some(decider) = &options.decider {
        agent = agent.with_decider(Box::new(OpenRouterDecider::new(&key, decider, OPENROUTER_URL)));
    }
    let script = kit_dir().join("browser").join("browser.mjs");
    let mut browser = Playwright::launch(&script, options.headed, options.viewport.0, options.viewport.1).map_err(|e| e.to_string())?.with_resources(loaded.files);
    browser.open(&start_url).map_err(|e| e.to_string())?;

    announce(&loaded.task, &options);
    let id = agent.start(loaded.task, Profile::new(facts));
    println!("run {id}: trace in {}", options.trace.join(&id).display());

    let mut results = Vec::new();
    let mut survey = false;
    let last = loop {
        let mut obs = browser.observe(survey).map_err(|e| format!("the browser could not look: {e}"))?;
        obs.results = std::mem::take(&mut results);
        let step = agent.step(&id, obs).map_err(|e| format!("the step failed: {e}"))?;
        show(&step);
        if step.status != Status::Working {
            break step;
        }
        results = browser.act(&step.actions).map_err(|e| format!("the browser could not act: {e}"))?;
        for result in results.iter().filter(|r| !r.ok) {
            println!("   ! {} failed: {}", result.id, result.error);
        }
        survey = step.survey;
        browser.after(&step);
    };
    conclude(&last);
    Ok(if last.status == Status::Done { 0 } else { 1 })
}

fn announce(task: &Task, options: &Options) {
    println!("task: {}", task.goal.lines().next().unwrap_or(""));
    if let Some(url) = &task.start_url {
        println!("start: {url}");
    }
    println!(
        "model: {} ({}), checker: {}, surveys {}, at most {} steps",
        options.model,
        options.reasoning,
        options.decider.as_deref().unwrap_or("none"),
        if task.survey { "on" } else { "off" },
        task.persistence.max_steps
    );
}

/// What one step decided, for the terminal.
fn show(step: &Step) {
    let status = serde_json::to_value(step.status).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default();
    println!("step {} {status}: {}", step.number, step.message);
    if !step.actions.is_empty() {
        println!("   -> {}", step.actions.iter().map(describe).collect::<Vec<_>>().join("; "));
    }
    for line in &step.dropped {
        println!("   dropped: {line}");
    }
    for question in &step.questions {
        println!("   question {}: {}", question.id, question.text);
    }
    if !step.fields.is_empty() {
        let list: Vec<String> = step.fields.iter().map(|f| format!("{:?} {}", f.label, serde_json::to_value(f.state).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default())).collect();
        println!("   to-do: {}", list.join("; "));
    }
    if step.survey {
        println!("   next look: a survey of the whole page");
    }
}

fn describe(action: &harness::action::Action) -> String {
    let label = if action.label.is_empty() { String::new() } else { format!(" {:?}", action.label) };
    match &action.kind {
        Kind::Type { text, secret: true } => format!("type [{} secret characters]", text.chars().count()),
        Kind::Type { text, .. } => format!("type {text:?}"),
        Kind::Key { keys } => format!("key {keys}"),
        Kind::Scroll { dy, .. } => format!("scroll {dy:+.0}"),
        Kind::Wait { ms } => format!("wait {ms}ms"),
        Kind::Survey => "survey".to_string(),
        other => {
            let name = serde_json::to_value(other).ok().and_then(|v| v["kind"].as_str().map(str::to_string)).unwrap_or_default();
            match other.point() {
                Some(p) => format!("{name} ({:.0},{:.0}){label}", p.x, p.y),
                None => name,
            }
        }
    }
}

/// The end of the run, for the terminal: the outcome and the report.
fn conclude(last: &Step) {
    println!();
    println!("{}", last.message);
    if let Some(stop) = &last.stop {
        println!("{} {}", stop.problem, stop.action);
    }
    if let Some(report) = &last.report {
        if !report.assumed.is_empty() {
            println!("assumed: {}", report.assumed.join("; "));
        }
        if !report.left.is_empty() {
            println!("left: {}", report.left.iter().map(|f| format!("{:?}", f.label)).collect::<Vec<_>>().join(", "));
        }
        for question in &report.questions {
            println!("asked: {} ({})", question.text, question.answer.as_deref().unwrap_or("no answer"));
        }
        if !report.not_seen.is_empty() {
            println!("not seen: {} part(s) of the last page", report.not_seen.len());
        }
        println!("{} steps, {} tokens in, {} out, ${:.4}", report.steps, report.usage.input_tokens, report.usage.output_tokens, report.usage.cost);
    }
}
