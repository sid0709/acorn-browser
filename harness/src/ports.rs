//! The traits the harness is written against: the driving model, the decision model, and the
//! browser. Each is replaceable; nothing in the core knows a provider or a browser by name.
//!
//! The traits are synchronous. A call blocks the thread that makes it, and work that must not
//! wait (a review of the last batch while the next one runs) goes on its own thread. This keeps
//! the port of Acorn's design one to one: a goroutine becomes a thread, a channel a channel.

use std::collections::BTreeMap;
use std::fmt;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::action::Action;
use crate::observe::{ActionResult, Observation};

/// The model that drives the run: it sees the screen and plans what to do. The only model that
/// ever plans or recovers.
pub trait Model {
    fn complete(&self, request: ModelRequest) -> Result<ModelResponse, Error>;
    /// The model's id, for the trace.
    fn name(&self) -> &str;
}

/// The model that answers typed questions about a state (a screenshot, or text) with
/// probabilities, and writes no prose. Cheap and quick; it never plans, only says yes or no,
/// or which.
pub trait Decider {
    fn decide(&self, decision: Decision) -> Result<Verdicts, Error>;
    /// The model's id, for the trace.
    fn name(&self) -> &str;
}

/// The eyes and hands: takes a look at the page and carries actions out.
pub trait Browser {
    /// The next look at the page. With `survey`, the whole page as screens from top to bottom.
    fn observe(&mut self, survey: bool) -> Result<Observation, Error>;
    /// Carries the actions out in order and says what became of each.
    fn act(&mut self, actions: &[Action]) -> Result<Vec<ActionResult>, Error>;
}

/// One message of the conversation sent to the driving model.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub role: Role,
    pub text: String,
    /// Data URLs of the images shown with the text.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<String>,
    /// Marks the end of a part of the prompt the next request repeats word for word (the system
    /// prompt, the history so far). A provider that caches only where it is told to is told
    /// here; one that caches every repeated prefix on its own ignores it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cache: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    System,
    #[default]
    User,
    Assistant,
}

/// What is asked of the driving model: the conversation, and the JSON schema its reply must fit.
#[derive(Clone, Debug, Default)]
pub struct ModelRequest {
    pub messages: Vec<Message>,
    pub schema_name: String,
    pub schema: serde_json::Value,
}

/// What the driving model answered, and what it cost.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelResponse {
    pub content: String,
    /// The model that answered, as the provider names it.
    pub model: String,
    /// Why the model stopped (`stop`, `length`, ...), as the provider names it.
    pub finish_reason: String,
    pub usage: Usage,
    /// How long the call took, retries included, and how many requests it sent.
    pub latency: Duration,
    pub attempts: u32,
}

/// Tokens and money one call cost.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    /// Input tokens the provider served from its cache.
    #[serde(default)]
    pub cached_tokens: u64,
    #[serde(default)]
    pub cache_write_tokens: u64,
    /// In dollars.
    pub cost: f64,
}

impl Usage {
    pub fn add(&mut self, other: Usage) {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.cached_tokens += other.cached_tokens;
        self.cache_write_tokens += other.cache_write_tokens;
        self.cost += other.cost;
    }
}

/// Questions asked of the decision model about one state.
#[derive(Clone, Debug, Default)]
pub struct Decision {
    /// The state the questions are about: text, screenshots, or both, in order.
    pub state: Vec<Part>,
    /// The questions, by the key each answer comes back under.
    pub questions: BTreeMap<String, Question>,
}

/// One part of a state.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Part {
    Text(String),
    /// A data URL.
    Image(String),
}

/// One typed question about the state.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Question {
    pub kind: QuestionKind,
    /// What to decide, in words.
    pub instructions: String,
    /// For a choice: the options by key, each described in words. Empty for yes/no.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub options: BTreeMap<String, String>,
}

impl Question {
    /// A question answered as the probability of yes.
    pub fn yes_no(instructions: impl Into<String>) -> Self {
        Question { kind: QuestionKind::YesNo, instructions: instructions.into(), options: BTreeMap::new() }
    }

    /// A question answered by picking one option, with a probability for each.
    pub fn choice(instructions: impl Into<String>, options: BTreeMap<String, String>) -> Self {
        Question { kind: QuestionKind::Choice, instructions: instructions.into(), options }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QuestionKind {
    #[default]
    YesNo,
    Choice,
}

/// The decision model's answers, by question key, and what they cost.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Verdicts {
    pub model: String,
    pub answers: BTreeMap<String, Answer>,
    pub usage: Usage,
    pub latency: Duration,
}

impl Verdicts {
    /// The probability of yes for a yes/no question, when it was answered.
    pub fn yes(&self, key: &str) -> Option<f64> {
        self.answers.get(key).and_then(|a| a.probability)
    }

    /// The option picked for a choice question, when it was answered.
    pub fn choice(&self, key: &str) -> Option<&str> {
        self.answers.get(key).and_then(|a| a.choice.as_deref())
    }
}

/// One answer. A yes/no question fills `probability`; a choice fills `choice` and
/// `probabilities`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Answer {
    /// The probability of yes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub probability: Option<f64>,
    /// The option picked, by key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub choice: Option<String>,
    /// The probability of each option, by key.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub probabilities: BTreeMap<String, f64>,
}

/// Why a call to a model or a browser failed. The kind says whether trying again can help.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error {
    pub kind: ErrorKind,
    pub message: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorKind {
    /// The request did not get through or the answer did not come back: a retry may help.
    Transport,
    /// The provider asked to slow down: a retry after a wait may help.
    RateLimited,
    /// The provider failed on its side: a retry may help.
    Server,
    /// The prompt is too long for the model: only a shorter prompt helps.
    ContextWindow,
    /// The request was wrong: a retry with the same request cannot help.
    BadRequest,
    /// The browser could not do what was asked.
    Browser,
    Other,
}

impl Error {
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Error { kind, message: message.into() }
    }

    /// Whether the same request may succeed if sent again.
    pub fn is_retryable(&self) -> bool {
        matches!(self.kind, ErrorKind::Transport | ErrorKind::RateLimited | ErrorKind::Server)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}: {}", self.kind, self.message)
    }
}

impl std::error::Error for Error {}
