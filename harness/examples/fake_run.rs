//! One full run of the loop against a scripted model, a checker that always agrees, and a
//! browser that only draws pictures. Run with `cargo run --example fake_run`.

use std::collections::BTreeMap;
use std::io::Cursor;
use std::sync::Mutex;

use base64::Engine;
use harness::action::Action;
use harness::observe::{ActionResult, Observation, Viewport};
use harness::ports::{Answer, Browser, Decider, Decision, Error, Model, ModelRequest, ModelResponse, Part, Usage, Verdicts};
use harness::profile::Profile;
use harness::run::{self, Agent, Config};
use harness::task::{Allowance, Irreversible, Task};
use harness::verify;

/// Answers each call with the next reply of its script, then repeats the last one.
struct Scripted {
    replies: Vec<&'static str>,
    calls: Mutex<usize>,
}

impl Model for Scripted {
    fn complete(&self, request: ModelRequest) -> Result<ModelResponse, Error> {
        let mut calls = self.calls.lock().unwrap();
        let reply = self.replies[(*calls).min(self.replies.len() - 1)];
        *calls += 1;
        let user = request.messages.last().map(|m| m.text.lines().next().unwrap_or("").to_string()).unwrap_or_default();
        println!("  model saw: {user}");
        Ok(ModelResponse {
            content: reply.to_string(),
            model: "scripted".to_string(),
            finish_reason: "stop".to_string(),
            usage: Usage { input_tokens: 1000, output_tokens: 50, cost: 0.001, ..Default::default() },
            ..Default::default()
        })
    }

    fn name(&self) -> &str {
        "scripted"
    }
}

/// A checker that finds every screen as expected, every point on its control, every field as
/// planned and the task done, with nothing in the way and nothing loading.
struct Nodding;

impl Decider for Nodding {
    fn decide(&self, decision: Decision) -> Result<Verdicts, Error> {
        let asked: Vec<&str> = decision.questions.keys().map(String::as_str).collect();
        let images = decision.state.iter().filter(|part| matches!(part, Part::Image(_))).count();
        println!("  checker saw {images} screenshot(s) and was asked about: {}", asked.join(", "));
        let mut answers = BTreeMap::new();
        for key in decision.questions.keys() {
            let probability = if key == verify::ASK_BLOCKED || key == verify::ASK_LOADING || key == "send_refused" { 0.0 } else { 1.0 };
            answers.insert(key.clone(), Answer { probability: Some(probability), ..Default::default() });
        }
        Ok(Verdicts { model: "nodding".to_string(), answers, usage: Usage { input_tokens: 300, cost: 0.0001, ..Default::default() }, ..Default::default() })
    }

    fn name(&self) -> &str {
        "nodding"
    }
}

/// A page that is a grey sheet with a dark bar that moves down one row per action taken.
struct Sheet {
    acted: u32,
}

impl Browser for Sheet {
    fn observe(&mut self, _survey: bool) -> Result<Observation, Error> {
        let (width, height) = (320u32, 240u32);
        let mut img = image::RgbImage::from_pixel(width, height, image::Rgb([235, 235, 235]));
        let top = (self.acted * 40) % height;
        for y in top..(top + 20).min(height) {
            for x in 0..width {
                img.put_pixel(x, y, image::Rgb([30, 30, 30]));
            }
        }
        let mut png = Vec::new();
        img.write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png).map_err(|e| Error::new(harness::ports::ErrorKind::Browser, e.to_string()))?;
        Ok(Observation {
            screenshot: format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(png)),
            url: "https://example.test/form".to_string(),
            title: "A form".to_string(),
            viewport: Viewport { width, height, page_height: height as f64, page_width: width as f64, ..Default::default() },
            ..Default::default()
        })
    }

    fn act(&mut self, actions: &[Action]) -> Result<Vec<ActionResult>, Error> {
        let mut results = Vec::new();
        for action in actions {
            println!("  browser did {}: {:?}", action.id, action.kind);
            self.acted += 1;
            results.push(ActionResult { id: action.id.clone(), ok: true, ..Default::default() });
        }
        Ok(results)
    }
}

fn main() {
    // The first reply plans the whole form: the batch after the first check runs when the checker
    // confirms the screen, without the model looking again.
    let script = vec![
        r#"{"observation":"An empty form.","memo":"Fill name, then send.","status":"working","message":"Filling the form.",
            "actions":[{"kind":"click","x":100,"y":50,"label":"Name","check":"the Name field is highlighted"},{"kind":"type","text":"A. Person"},
            {"kind":"click","x":100,"y":200,"label":"Send","commit":"send","check":"a thank-you message"}]}"#,
        r#"{"observation":"Thank you, your form was received.","memo":null,"status":"done","message":"The form was sent.","actions":[]}"#,
    ];
    let agent = Agent::new(Config::default(), Box::new(Scripted { replies: script, calls: Mutex::new(0) })).with_decider(Box::new(Nodding));
    // The person lets the run send on its own; every other kind of irreversible action is asked about.
    let task = Task::new("Fill the form at https://example.test/form and send it.").allow(Irreversible::Send, Allowance::Auto);
    let id = agent.start(task, Profile::new("Name: A. Person"));
    println!("run {id}");
    let mut browser = Sheet { acted: 0 };
    match run::drive(&agent, &id, &mut browser) {
        Ok(step) => {
            println!("ended at step {}: {:?} - {}", step.number, step.status, step.message);
            println!("usage: {} in, {} out, ${:.4}", step.usage.input_tokens, step.usage.output_tokens, step.usage.cost);
            if let Some(report) = step.report {
                println!("report: {} steps, {} assumed, {} questions, {} fields left", report.steps, report.assumed.len(), report.questions.len(), report.left.len());
            }
        }
        Err(err) => {
            eprintln!("the run failed: {err}");
            std::process::exit(1);
        }
    }
    agent.end(&id);
}
