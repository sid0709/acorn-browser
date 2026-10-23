//! Runs one task from a Markdown file against a real browser: the harness decides, Playwright
//! looks and does, OpenRouter answers.
//!
//! ```text
//! OPENROUTER_API_KEY=... cargo run -- tasks/local-form.md
//!   --headed                 show the browser window
//!   --model <id>             the driving model (default openai/gpt-6-luna)
//!   --decider <id> | none    the decision model on a Decisions API (default openai/gpt-6-luna-decisions
//!                            on OpenRouter; none turns the checks off)
//!   --decisions openrouter | openai
//!                            whose Decisions API answers (OpenAI's needs OPENAI_API_KEY; default openrouter)
//!   --reasoning <effort>     none, low, medium or high for the driving model (default none)
//!   --bench                  no task: time a few small calls to each model, to see how the provider is doing
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
use std::time::Instant;

use harness::action::Kind;
use harness::intake;
use harness::openrouter::{OpenRouter, UreqTransport};
use harness::ports::Browser;
use harness::profile::Profile;
use harness::run::{Agent, Config, Status, Step};
use harness::task::Task;

use crate::browser::Playwright;
use crate::decide::{Decisions, Meter, Metered, Tally, Wire};

const OPENROUTER_URL: &str = "https://openrouter.ai/api/v1";
const DEFAULT_MODEL: &str = "openai/gpt-6-luna";
const DEFAULT_REASONING: &str = "none";
const DEFAULT_VIEWPORT: (u32, u32) = (1280, 720);
/// The facts the run acts on when no profile file is given or found.
const DEFAULT_FACTS: &str = "The person gave no details about themselves.";

struct Options {
    task: PathBuf,
    bench: bool,
    headed: bool,
    model: String,
    decider: Option<String>,
    decisions: Wire,
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
        bench: false,
        headed: false,
        model: DEFAULT_MODEL.to_string(),
        decider: None,
        decisions: Wire::OpenRouter,
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
            "--bench" => out.bench = true,
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
    if out.task.as_os_str().is_empty() && !out.bench {
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

const USAGE: &str = "usage: harness-kit <task.md> | --bench [--headed] [--model <id>] [--decider <id>|none] [--decisions openrouter|openai] [--reasoning <effort>] [--profile <file>] [--trace <dir>] [--viewport <WxH>]";

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
    if options.bench {
        return bench(&options, &key);
    }
    let mut loaded = taskfile::load(&options.task)?;
    let facts = std::fs::read_to_string(&options.profile).unwrap_or_else(|_| DEFAULT_FACTS.to_string());

    let model_meter = Meter::default();
    let check_meter = Meter::default();
    let model = Metered { inner: OpenRouter::new(key.clone(), options.model.clone(), OPENROUTER_URL, options.reasoning.clone(), Box::new(UreqTransport::default())), meter: model_meter.clone() };
    // A task with no url: or done_when: line is read by the model first, as a chat request is.
    if intake::needed(&loaded.task) {
        let sheet = intake::understand(&model, &loaded.task.goal, &Profile::new(facts.clone())).map_err(|e| format!("the request could not be understood: {e}"))?;
        intake::apply(&sheet, &mut loaded.task);
        println!("understood: {}", sheet.summary);
        println!("  start at {}", loaded.task.start_url.as_deref().unwrap_or("(the page the browser shows)"));
        println!("  done when {}", loaded.task.done_when);
    }
    let start_url = loaded.task.start_url.clone().ok_or("the task names no site to start on: add a url: line")?;
    let mut agent = Agent::new(Config::default(), Box::new(model)).with_trace_dir(&options.trace);
    if let Some(decider) = &options.decider {
        let (decision_key, url) = match options.decisions {
            Wire::OpenRouter => (key.clone(), decide::OPENROUTER_DECISIONS_URL),
            Wire::OpenAI => (std::env::var("OPENAI_API_KEY").ok().filter(|k| !k.trim().is_empty()).ok_or("set OPENAI_API_KEY (in the environment or kit/.env) for OpenAI's Decisions API")?, decide::OPENAI_DECISIONS_URL),
        };
        let mut checker = Decisions::new(&decision_key, decider, url, options.decisions);
        checker.meter = check_meter.clone();
        agent = agent.with_decider(Box::new(checker));
    }
    let script = kit_dir().join("browser").join("browser.mjs");
    let mut browser = Playwright::launch(&script, options.headed, options.viewport.0, options.viewport.1).map_err(|e| e.to_string())?.with_resources(loaded.files);
    browser.open(&start_url).map_err(|e| e.to_string())?;

    announce(&loaded.task, &options);
    let id = agent.start(loaded.task, Profile::new(facts));
    println!("run {id}: trace in {}", options.trace.join(&id).display());

    let started = Instant::now();
    let mut results = Vec::new();
    let mut survey = false;
    let last = loop {
        let step_started = Instant::now();
        let mut obs = browser.observe(survey).map_err(|e| format!("the browser could not look: {e}"))?;
        let looked = step_started.elapsed();
        obs.results = std::mem::take(&mut results);
        let step = agent.step(&id, obs).map_err(|e| format!("the step failed: {e}"))?;
        show(&step, looked.as_secs_f64(), step_started.elapsed().as_secs_f64() - looked.as_secs_f64(), started.elapsed().as_secs_f64());
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
    conclude(&last, started.elapsed().as_secs_f64(), model_meter.read(), check_meter.read());
    Ok(if last.status == Status::Done { 0 } else { 1 })
}

/// How many calls the bench makes to each model.
const BENCH_CALLS: usize = 3;

/// Times a few small calls to the driving model and the decision model, with one small
/// screenshot, and prints each: the first call pays the connection, the rest show the provider.
fn bench(options: &Options, key: &str) -> Result<i32, String> {
    use harness::ports::{Decider, Decision, Message, Model, ModelRequest, Question, Role};
    let image = tiny_screenshot();
    println!("bench: {BENCH_CALLS} calls each, one {}x{} screenshot", BENCH_SIZE.0, BENCH_SIZE.1);
    let model = OpenRouter::new(key, options.model.clone(), OPENROUTER_URL, options.reasoning.clone(), Box::new(UreqTransport::default()));
    println!("model {} ({}):", options.model, options.reasoning);
    for n in 1..=BENCH_CALLS {
        let request = ModelRequest {
            messages: vec![
                Message { role: Role::System, text: "Answer with the JSON object asked for.".into(), ..Default::default() },
                Message { role: Role::User, text: "What colour is the picture? Reply {\"colour\": \"...\"}.".into(), images: vec![image.clone()], ..Default::default() },
            ],
            schema_name: "colour".into(),
            schema: serde_json::json!({"type": "object", "additionalProperties": false, "required": ["colour"], "properties": {"colour": {"type": "string"}}}),
        };
        let started = Instant::now();
        match model.complete(request) {
            Ok(r) => println!("  call {n}: {:.2}s, {} in (cached {}), {} out, ${:.5}, {} http attempt(s), answered {}", started.elapsed().as_secs_f64(), r.usage.input_tokens, r.usage.cached_tokens, r.usage.output_tokens, r.usage.cost, r.attempts, r.content.trim()),
            Err(e) => println!("  call {n}: failed after {:.2}s: {e}", started.elapsed().as_secs_f64()),
        }
    }
    let Some(decider) = &options.decider else { return Ok(0) };
    let (decision_key, url) = match options.decisions {
        Wire::OpenRouter => (key.to_string(), decide::OPENROUTER_DECISIONS_URL),
        Wire::OpenAI => (std::env::var("OPENAI_API_KEY").map_err(|_| "set OPENAI_API_KEY for --decisions openai")?, decide::OPENAI_DECISIONS_URL),
    };
    let checker = Decisions::new(&decision_key, decider, url, options.decisions);
    println!("checker {decider} on {}:", if options.decisions == Wire::OpenAI { "openai" } else { "openrouter" });
    for n in 1..=BENCH_CALLS {
        let mut questions = std::collections::BTreeMap::new();
        questions.insert("grey".to_string(), Question::yes_no("Is the picture a plain grey rectangle?"));
        let decision = Decision { state: vec![harness::ports::Part::Text("A screenshot.".into()), harness::ports::Part::Image(image.clone())], questions };
        let started = Instant::now();
        match checker.decide(decision) {
            Ok(v) => println!("  call {n}: {:.2}s, {} in, ${:.5}, grey={:.2}", started.elapsed().as_secs_f64(), v.usage.input_tokens, v.usage.cost, v.yes("grey").unwrap_or(0.0)),
            Err(e) => println!("  call {n}: failed after {:.2}s: {e}", started.elapsed().as_secs_f64()),
        }
    }
    Ok(0)
}

/// The size of the bench's screenshot.
const BENCH_SIZE: (u32, u32) = (320, 200);

/// A plain grey JPEG data URL, so the bench measures the provider and not a big upload.
fn tiny_screenshot() -> String {
    use harness::base64::Engine;
    let (w, h) = BENCH_SIZE;
    let mut jpeg = Vec::new();
    let img = harness::image::RgbImage::from_pixel(w, h, harness::image::Rgb([200, 200, 200]));
    harness::image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 80).encode_image(&img).expect("a jpeg");
    format!("data:image/jpeg;base64,{}", harness::base64::engine::general_purpose::STANDARD.encode(jpeg))
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
        match &options.decider {
            Some(model) => format!("{model} on {}", if options.decisions == Wire::OpenAI { "openai" } else { "openrouter" }),
            None => "none".to_string(),
        },
        if task.survey { "on" } else { "off" },
        task.persistence.max_steps
    );
}

/// What one step decided, for the terminal, with the seconds the look and the decision took and
/// the seconds since the run began.
fn show(step: &Step, looked: f64, decided: f64, elapsed: f64) {
    let status = serde_json::to_value(step.status).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default();
    println!("[{elapsed:6.1}s] step {} {status}: {} (look {looked:.1}s, decide {decided:.1}s)", step.number, step.message);
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
        Kind::Navigate { url } => format!("go to {url}"),
        Kind::Back => "go back".to_string(),
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
fn conclude(last: &Step, elapsed: f64, model: Tally, checks: Tally) {
    println!();
    println!("{} ({elapsed:.1}s in all)", last.message);
    let line = |what: &str, t: Tally| {
        if t.calls > 0 {
            println!(
                "{what}: {} calls, {:.1}s waited ({:.1}s each), {} in (cached {}), {} out, ${:.4}",
                t.calls,
                t.waited.as_secs_f64(),
                t.waited.as_secs_f64() / t.calls as f64,
                t.usage.input_tokens,
                t.usage.cached_tokens,
                t.usage.output_tokens,
                t.usage.cost
            );
        }
    };
    line("model", model);
    line("checks", checks);
    println!("browser and harness: {:.1}s", (elapsed - model.waited.as_secs_f64() - checks.waited.as_secs_f64()).max(0.0));
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
        println!("{} steps, ${:.4} in all", report.steps, report.usage.cost);
    }
}
