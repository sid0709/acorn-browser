//! Fakes for the tests: a model that answers with one fixed reply and keeps what it was told, a
//! decider that is sure of some answers, and looks at a plain page.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::change;
use crate::observe::{ActionResult, Observation, Viewport};
use crate::ports::{Answer, Decider, Decision, Error, Model, ModelRequest, ModelResponse, Verdicts};

/// Answers every call with the same reply, and keeps the text of the last message of each call.
pub(crate) struct Replying {
    reply: String,
    pub seen: Arc<Mutex<Vec<String>>>,
}

impl Replying {
    /// The model, and the texts it will be sent, to read after the run.
    pub fn new(reply: &str) -> (Box<Replying>, Arc<Mutex<Vec<String>>>) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        (Box::new(Replying { reply: reply.to_string(), seen: seen.clone() }), seen)
    }
}

impl Model for Replying {
    fn complete(&self, request: ModelRequest) -> Result<ModelResponse, Error> {
        self.seen.lock().unwrap().push(request.messages.last().map(|m| m.text.clone()).unwrap_or_default());
        Ok(ModelResponse { content: self.reply.clone(), ..Default::default() })
    }

    fn name(&self) -> &str {
        "replying"
    }
}

/// Answers each yes/no question with the probability set for its key, and no to the rest.
pub(crate) struct Sure(BTreeMap<String, f64>);

impl Sure {
    pub fn of(answers: &[(&str, f64)]) -> Box<Sure> {
        Box::new(Sure(answers.iter().map(|(key, p)| (key.to_string(), *p)).collect()))
    }
}

impl Decider for Sure {
    fn decide(&self, decision: Decision) -> Result<Verdicts, Error> {
        let answers = decision
            .questions
            .keys()
            .map(|key| (key.clone(), Answer { probability: Some(self.0.get(key).copied().unwrap_or(0.0)), ..Default::default() }))
            .collect();
        Ok(Verdicts { answers, ..Default::default() })
    }

    fn name(&self) -> &str {
        "sure"
    }
}

/// A look at an 80x60 page, plain or with a dark mark, with these actions reported done.
pub(crate) fn look(mark: bool, done: &[&str]) -> Observation {
    Observation {
        screenshot: change::test_screenshot(80, 60, mark),
        viewport: Viewport { width: 80, height: 60, page_width: 80.0, page_height: 60.0, ..Default::default() },
        results: done.iter().map(|id| ActionResult { id: id.to_string(), ok: true, ..Default::default() }).collect(),
        ..Default::default()
    }
}
