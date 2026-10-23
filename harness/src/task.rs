//! The task as the harness understands it: the goal, what "done" looks like, the resources
//! given, and how hard to push before stopping. Built from the chat message that started the run.
//!
//! A sentence in the prompt is advice, not a guard. What the person said about the task ("create
//! an account if you must", "do not stop unless you have to") lives here as numbers and lists the
//! gates read, so the run keeps the promise whether or not the model remembers it.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use serde::{Deserialize, Serialize};

/// One task, as given in chat and read into shape.
#[derive(Clone, Debug)]
pub struct Task {
    /// The goal in the person's words.
    pub goal: String,
    /// Where to begin. `None` means the page the browser is on.
    pub start_url: Option<String>,
    /// What the screen shows when the task is done, in words. Written at the start, by the
    /// person or by the model from the goal. A "done" from the model is checked against it.
    pub done_when: String,
    /// How to go about the task, a few conditional lines ("if a sort control is in view, sort by
    /// it before taking the top row"), and what to watch out for. Written at the start, by the
    /// person or by the model from the goal; a model with no reasoning of its own does far better
    /// when the thinking was done before the run. Empty leaves the model to its own judgment.
    pub approach: Vec<String>,
    pub watch_out: Vec<String>,
    /// Files the task may use. The model sees ids, names and descriptions; the bytes stay here
    /// and go to the browser only at an upload.
    pub resources: Vec<Resource>,
    /// How hard to push before the run ends for the person.
    pub persistence: Persistence,
    /// What the run may do on its own among the actions that commit something beyond the page.
    /// A kind not listed is asked about.
    pub allowances: BTreeMap<Irreversible, Allowance>,
    /// Whether the run may look at a whole long page as several screenshots (a survey) and plan
    /// it at once. Off, the model sees one screen at a time, as a person does.
    pub survey: bool,
}

impl Task {
    /// A task with a goal and the defaults: 150 steps, stops where a person is needed, asks
    /// before anything irreversible, surveys on.
    pub fn new(goal: impl Into<String>) -> Self {
        Task {
            goal: goal.into(),
            start_url: None,
            done_when: String::new(),
            approach: Vec::new(),
            watch_out: Vec::new(),
            resources: Vec::new(),
            persistence: Persistence::default(),
            allowances: BTreeMap::new(),
            survey: true,
        }
    }

    /// Sets what the run may do on its own for one kind of irreversible action.
    pub fn allow(mut self, kind: Irreversible, allowance: Allowance) -> Self {
        self.allowances.insert(kind, allowance);
        self
    }

    /// What the run may do for one kind of irreversible action: what was set, else ask.
    pub fn allowance(&self, kind: Irreversible) -> Allowance {
        self.allowances.get(&kind).copied().unwrap_or(Allowance::Ask)
    }

    /// Whether the run may end for the person for this reason. The harness's own reasons (the
    /// page stopped responding, the step limit) always may; the model's are policy.
    pub fn may_stop_for(&self, reason: StopReason) -> bool {
        reason.is_harness_own() || self.persistence.stop_for.contains(&reason)
    }

    /// The resource with this id, when the task has one.
    pub fn resource(&self, id: &str) -> Option<&Resource> {
        self.resources.iter().find(|r| r.id == id)
    }
}

/// A file the task may use.
#[derive(Clone)]
pub struct Resource {
    /// How the model names it.
    pub id: String,
    /// The file name the page gets.
    pub name: String,
    /// The media type (`application/pdf`, ...).
    pub media_type: String,
    /// What it is, in words, for the model to choose by.
    pub description: String,
    pub bytes: Vec<u8>,
}

impl fmt::Debug for Resource {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Resource")
            .field("id", &self.id)
            .field("name", &self.name)
            .field("media_type", &self.media_type)
            .field("description", &self.description)
            .field("bytes", &format_args!("{} bytes", self.bytes.len()))
            .finish()
    }
}

/// How hard the run pushes before it ends for the person.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Persistence {
    /// The most steps the run may take before it ends as stuck.
    pub max_steps: u32,
    /// The reasons the model may end the run for the person. A stop for any other reason is sent
    /// back with a note to keep going.
    pub stop_for: BTreeSet<StopReason>,
}

impl Persistence {
    pub const DEFAULT_MAX_STEPS: u32 = 150;

    /// Push to the end: stop only for what a person alone can do (a CAPTCHA, a code, an
    /// identity, money, credentials the run does not have, a site that refuses the account, a
    /// task the page says cannot be done here).
    pub fn relentless() -> Self {
        Persistence { max_steps: Self::DEFAULT_MAX_STEPS, stop_for: StopReason::unavoidable() }
    }
}

impl Default for Persistence {
    /// Stop for what a person alone can do, for a page that would not take what was asked of it,
    /// and for a decision or anything else the model judges the person must see.
    fn default() -> Self {
        let mut stop_for = StopReason::unavoidable();
        stop_for.insert(StopReason::PageProblem);
        stop_for.insert(StopReason::Decision);
        stop_for.insert(StopReason::Other);
        Persistence { max_steps: Self::DEFAULT_MAX_STEPS, stop_for }
    }
}

/// Why a run ends without being done. The model names the first eleven; the harness itself the
/// rest.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    /// A human check on the page.
    Captcha,
    /// A code sent to a phone or an inbox the run cannot read.
    VerificationCode,
    /// A link in an email the person must open.
    VerificationLink,
    /// An identity number, a document, or a legal signature.
    Identity,
    /// Money.
    Payment,
    /// A sign-in the run has no credentials for.
    Credentials,
    /// The site refused the sign-in, the new account, and the password reset.
    AccountRejected,
    /// The page shows the task cannot be done here (closed, offline only, the wrong page).
    Unavailable,
    /// A choice only the person can make.
    Decision,
    /// The page would not take what was asked of it.
    PageProblem,
    Other,
    /// The screen did not change for too many steps in a row.
    NoChange,
    /// The run reached its step limit.
    StepLimit,
    /// The same action failed too many steps in a row.
    RepeatedFailure,
    /// The model said done, but the screen never confirmed it.
    NotConfirmed,
    /// An action the person reserved for themselves was all that was left: the run ends ready
    /// for them to do it.
    Reserved,
}

impl StopReason {
    /// The reasons a person alone can deal with: the floor of any persistence policy.
    pub fn unavoidable() -> BTreeSet<StopReason> {
        [
            StopReason::Captcha,
            StopReason::VerificationCode,
            StopReason::VerificationLink,
            StopReason::Identity,
            StopReason::Payment,
            StopReason::Credentials,
            StopReason::AccountRejected,
            StopReason::Unavailable,
        ]
        .into_iter()
        .collect()
    }

    /// Whether the harness, not the model, names this reason: these end the run whatever the
    /// policy says, because the harness has already judged the run cannot go on.
    pub fn is_harness_own(self) -> bool {
        matches!(
            self,
            StopReason::NoChange | StopReason::StepLimit | StopReason::RepeatedFailure | StopReason::NotConfirmed | StopReason::Reserved
        )
    }
}

/// An action that commits something beyond the page and cannot be taken back.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Irreversible {
    /// Sends or submits to someone: an application, a message, an order.
    Send,
    Pay,
    /// Publishes where others see it.
    Post,
    Delete,
    CreateAccount,
}

impl Irreversible {
    /// The action as a verb phrase: "send or submit", "pay", ...
    pub fn verb(self) -> &'static str {
        match self {
            Irreversible::Send => "send or submit",
            Irreversible::Pay => "pay",
            Irreversible::Post => "post",
            Irreversible::Delete => "delete",
            Irreversible::CreateAccount => "create an account",
        }
    }
}

/// What the run may do on its own for one kind of irreversible action.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Allowance {
    /// Do it without asking.
    Auto,
    /// Ask the person first; go on with the rest of the task while waiting.
    #[default]
    Ask,
    /// Never do it; when nothing else is left, end the run as ready for the person to do it.
    Never,
}
