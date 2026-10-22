//! The browser side against the local page, with no model: it proves the plumbing between the
//! harness's shapes and Playwright, not the model. Skipped, with a line on stderr, when Node with
//! Playwright is not installed (run `npm install` in kit/browser).

use std::path::PathBuf;
use std::process::Command;

use harness::action::{Action, Kind};
use harness::observe::Observation;
use harness::ports::{Browser, Error, Model, ModelRequest, ModelResponse};
use harness::profile::Profile;
use harness::run::{Agent, Config, Status};
use harness::task::Task;

#[allow(dead_code)]
#[path = "../src/browser.rs"]
mod browser;
use browser::Playwright;

fn kit() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn playwright_installed() -> bool {
    Command::new("node")
        .arg("-e")
        .arg("import('playwright').then(() => process.exit(0), () => process.exit(1))")
        .current_dir(kit().join("browser"))
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// A model that answers with one fixed reply.
struct Fixed(&'static str);

impl Model for Fixed {
    fn complete(&self, _: ModelRequest) -> Result<ModelResponse, Error> {
        Ok(ModelResponse { content: self.0.to_string(), ..Default::default() })
    }
    fn name(&self) -> &str {
        "fixed"
    }
}

fn click(id: &str, x: f64, y: f64) -> Action {
    Action::new(id, Kind::Click { x, y })
}

fn typed(id: &str, text: &str) -> Action {
    Action::new(id, Kind::Type { text: text.to_string(), secret: false })
}

#[test]
fn the_local_form_is_filled_and_sent_through_playwright() {
    if !playwright_installed() {
        eprintln!("skipped: node with playwright is not installed (run npm install in kit/browser)");
        return;
    }
    let page = format!("file://{}", kit().join("pages").join("form.html").display());
    let mut browser = Playwright::launch(&kit().join("browser").join("browser.mjs"), false, 800, 600).unwrap();
    browser.open(&page).unwrap();

    let look: Observation = browser.observe(false).unwrap();
    assert_eq!((look.viewport.width, look.viewport.height), (800, 600));
    assert_eq!(look.title, "A small form");
    assert!(look.screenshot.starts_with("data:image/jpeg;base64,"));
    assert!(look.focus.is_none());

    // The harness reads the look: the screenshot is the size the viewport says.
    let agent = Agent::new(Config::default(), Box::new(Fixed(r#"{"status":"working","message":"Looking.","actions":[{"kind":"wait","ms":100}]}"#)));
    let id = agent.start(Task::new("order a kettle"), Profile::default());
    assert_eq!(agent.step(&id, look).unwrap().status, Status::Working);

    // Typing with nothing focused reaches no control; the rest of the batch goes on.
    let results = browser.act(&[typed("s1a1", "nowhere"), click("s1a2", 190.0, 116.0)]).unwrap();
    assert!(!results[0].ok && results[0].unreached, "{:?}", results[0]);
    assert!(results[1].ok);
    let focused = browser.observe(false).unwrap().focus.unwrap();
    assert_eq!((focused.tag.as_str(), focused.label.as_str()), ("input", "Full name *"));

    // The form is filled and sent: the page says so in its title.
    let plan = [typed("s2a1", "A. Person"), click("s2a2", 190.0, 186.0), typed("s2a3", "a.person@example.com"), click("s2a4", 120.0, 360.0)];
    let results = browser.act(&plan).unwrap();
    assert!(results.iter().all(|r| r.ok), "{results:?}");
    let after = browser.observe(false).unwrap();
    assert_eq!(after.title, "Sent");
    assert!(after.url.ends_with("#sent"), "{}", after.url);
}
