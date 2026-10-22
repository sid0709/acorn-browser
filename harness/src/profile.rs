//! Who the agent acts as: the facts the person gave about themselves, for the model to fill the
//! page from.
//!
//! The harness holds no credentials. Sign-ins are the browser side's business (its own
//! credential store, or the person at the keyboard), so no password ever reaches a prompt, the
//! history, or a trace.

/// The person the run acts as.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Profile {
    /// What the model may know, as text: name, background, preferences, whatever the person
    /// gave in chat. Goes into the system prompt, so it is cached and sent with every step.
    pub facts: String,
}

impl Profile {
    pub fn new(facts: impl Into<String>) -> Self {
        Profile { facts: facts.into() }
    }
}
