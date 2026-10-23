//! The browser port of the kit: a Playwright page in a Node process, driven over its stdin and
//! stdout with one JSON object per line (`browser/browser.mjs`). The harness never knows it is
//! Playwright: it sees the `Browser` trait, and the observation and the actions are its own
//! shapes, as serde writes them.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

use harness::action::{Action, Kind};
use harness::map::SettledMap;
use harness::observe::{ActionResult, Observation};
use harness::ports::{Browser, Error, ErrorKind};
use harness::run::Step;
use serde_json::{Value, json};

/// How long the browser gets to close on its own before it is killed.
const CLOSE_WAIT: Duration = Duration::from_secs(3);

/// The page as Playwright drives it.
pub struct Playwright {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_id: u64,
    /// Where the next survey must show fields whole, and the parts of the page it may leave out.
    focus: Vec<f64>,
    settled: Option<SettledMap>,
    /// The files the task may upload, by the id the model uses.
    resources: HashMap<String, PathBuf>,
}

impl Playwright {
    /// Starts the browser: `node <script>` with the window size, headed when asked.
    pub fn launch(script: &Path, headed: bool, width: u32, height: u32) -> Result<Self, Error> {
        let mut command = Command::new("node");
        command.arg(script).arg("--width").arg(width.to_string()).arg("--height").arg(height.to_string());
        if headed {
            command.arg("--headed");
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|e| Error::new(ErrorKind::Browser, format!("could not start node: {e}")))?;
        let stdin = child.stdin.take().expect("a piped stdin");
        let stdout = BufReader::new(child.stdout.take().expect("a piped stdout"));
        Ok(Playwright { child, stdin, stdout, next_id: 0, focus: Vec::new(), settled: None, resources: HashMap::new() })
    }

    /// Gives the browser the files the task may upload, by id.
    pub fn with_resources(mut self, resources: HashMap<String, PathBuf>) -> Self {
        self.resources = resources;
        self
    }

    /// Opens the page the task starts on.
    pub fn open(&mut self, url: &str) -> Result<(), Error> {
        self.call(json!({"cmd": "open", "url": url})).map(|_| ())
    }

    /// Takes from a step what the next look needs: where the survey must show fields whole, and
    /// the parts of the page it may leave out.
    pub fn after(&mut self, step: &Step) {
        self.focus = step.survey_focus.clone();
        if let Some(map) = &step.settled {
            self.settled = Some(map.clone());
        }
    }

    /// Sends one request and reads its reply.
    fn call(&mut self, mut request: Value) -> Result<Value, Error> {
        self.next_id += 1;
        request["id"] = json!(self.next_id);
        let line = serde_json::to_string(&request).map_err(|e| Error::new(ErrorKind::Browser, e.to_string()))?;
        self.stdin
            .write_all(line.as_bytes())
            .and_then(|_| self.stdin.write_all(b"\n"))
            .and_then(|_| self.stdin.flush())
            .map_err(|e| Error::new(ErrorKind::Browser, format!("the browser went away: {e}")))?;
        let mut reply = String::new();
        loop {
            reply.clear();
            let read = self.stdout.read_line(&mut reply).map_err(|e| Error::new(ErrorKind::Browser, format!("the browser went away: {e}")))?;
            if read == 0 {
                return Err(Error::new(ErrorKind::Browser, "the browser closed its side"));
            }
            if reply.trim().is_empty() {
                continue;
            }
            let value: Value = serde_json::from_str(&reply).map_err(|e| Error::new(ErrorKind::Browser, format!("the browser sent something other than JSON: {e}")))?;
            if value["id"] != json!(self.next_id) {
                continue;
            }
            if value["ok"] != json!(true) {
                return Err(Error::new(ErrorKind::Browser, value["error"].as_str().unwrap_or("the browser failed").to_string()));
            }
            return Ok(value);
        }
    }
}

impl Browser for Playwright {
    fn observe(&mut self, survey: bool) -> Result<Observation, Error> {
        let request = json!({"cmd": "observe", "survey": survey, "focus": std::mem::take(&mut self.focus), "settled": self.settled});
        let reply = self.call(request)?;
        serde_json::from_value(reply["observation"].clone()).map_err(|e| Error::new(ErrorKind::Browser, format!("the browser sent a look the harness cannot read: {e}")))
    }

    fn act(&mut self, actions: &[Action]) -> Result<Vec<ActionResult>, Error> {
        let mut sent = Vec::with_capacity(actions.len());
        for action in actions {
            let mut value = serde_json::to_value(action).map_err(|e| Error::new(ErrorKind::Browser, e.to_string()))?;
            if let Kind::Upload { resource, .. } = &action.kind {
                // The bytes stay with the task; the browser gets the path of the file to hand
                // the page. With no id, the task's first file.
                let path = if resource.is_empty() { self.resources.values().next() } else { self.resources.get(resource) };
                if let Some(path) = path {
                    value["path"] = json!(path);
                    value["fileName"] = json!(path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default());
                }
            }
            sent.push(value);
        }
        let reply = self.call(json!({"cmd": "act", "actions": sent}))?;
        serde_json::from_value(reply["results"].clone()).map_err(|e| Error::new(ErrorKind::Browser, format!("the browser sent results the harness cannot read: {e}")))
    }
}

impl Drop for Playwright {
    fn drop(&mut self) {
        let _ = self.call(json!({"cmd": "close"}));
        let started = Instant::now();
        while started.elapsed() < CLOSE_WAIT {
            if matches!(self.child.try_wait(), Ok(Some(_))) {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
