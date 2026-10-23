//! The browser port of the runner: the Acorn Browser app, reached over its agent socket. The app
//! speaks one JSON object per line each way (`open`, `observe`, `act`, `close`), the protocol the
//! kit's Playwright process speaks; the harness sees only the `Browser` trait, and the
//! observation and the actions are its own shapes, as serde writes them.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use harness::action::{Action, Kind};
use harness::map::SettledMap;
use harness::observe::{ActionResult, Observation};
use harness::ports::{Browser, Error, ErrorKind};
use harness::run::Step;
use serde_json::{Value, json};

/// The version of the line protocol this runner speaks; the app must speak the same.
pub const PROTOCOL: u64 = 4;

/// How long one request may take before the app is taken to be stuck. A look waits for the page
/// to settle (a few seconds) and a survey scrolls the whole page, so this is generous.
const REPLY_WAIT: Duration = Duration::from_secs(120);

/// The app's page, as the harness drives it.
pub struct AppBrowser {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    next_id: u64,
    /// Where the next survey must show fields whole, and the parts of the page it may leave out.
    focus: Vec<f64>,
    settled: Option<SettledMap>,
    /// The files the task may upload, by the id the model uses.
    resources: HashMap<String, PathBuf>,
}

impl AppBrowser {
    /// Connects to the app's agent socket.
    pub fn connect(socket: &Path) -> Result<Self, Error> {
        let stream = UnixStream::connect(socket).map_err(|e| {
            Error::new(ErrorKind::Browser, format!("cannot reach the browser at {}: {e} (is the app running?)", socket.display()))
        })?;
        stream.set_read_timeout(Some(REPLY_WAIT)).map_err(|e| Error::new(ErrorKind::Browser, e.to_string()))?;
        let reader = stream.try_clone().map_err(|e| Error::new(ErrorKind::Browser, e.to_string()))?;
        let mut browser = AppBrowser { writer: stream, reader: BufReader::new(reader), next_id: 0, focus: Vec::new(), settled: None, resources: HashMap::new() };
        browser.handshake()?;
        Ok(browser)
    }

    /// Makes sure the app speaks the same protocol as this runner: an app built before a kind
    /// of action was added would refuse it mid-run, and look like a page that does not work.
    fn handshake(&mut self) -> Result<(), Error> {
        let reply = self.call(json!({"cmd": "hello", "protocol": PROTOCOL})).map_err(|e| {
            Error::new(ErrorKind::Browser, format!("the app did not answer the greeting ({e}): it is older than this runner; rebuild it with app/scripts/build.sh"))
        })?;
        let spoken = reply["protocol"].as_u64().unwrap_or(0);
        if spoken != PROTOCOL {
            return Err(Error::new(
                ErrorKind::Browser,
                format!("the app speaks protocol {spoken} and this runner protocol {PROTOCOL}: rebuild both with app/scripts/build.sh"),
            ));
        }
        Ok(())
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
        self.writer
            .write_all(line.as_bytes())
            .and_then(|_| self.writer.write_all(b"\n"))
            .and_then(|_| self.writer.flush())
            .map_err(|e| Error::new(ErrorKind::Browser, format!("the browser went away: {e}")))?;
        let mut reply = String::new();
        loop {
            reply.clear();
            let read = self.reader.read_line(&mut reply).map_err(|e| Error::new(ErrorKind::Browser, format!("the browser did not answer: {e}")))?;
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

impl Browser for AppBrowser {
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

impl Drop for AppBrowser {
    fn drop(&mut self) {
        let _ = self.call(json!({"cmd": "close"}));
    }
}
