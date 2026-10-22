//! One run of one task: the task, the profile it acts as, the model's memory, and the run's state.

use std::hash::{BuildHasher, Hasher, RandomState};
use std::time::{Instant, SystemTime};

use crate::change::Signature;
use crate::memory::Memory;
use crate::observe::ActionResult;
use crate::ports::Usage;
use crate::profile::Profile;
use crate::task::Task;

/// One application of the harness to one task, from the first look to the end.
#[derive(Debug)]
pub struct Session {
    pub id: String,
    pub task: Task,
    pub profile: Profile,
    pub created: SystemTime,
    /// When the run last did anything, for expiring idle sessions.
    pub touched: Instant,
    /// Counts every step asked, the failed ones included; names the trace entries.
    pub seq: u32,
    /// Counts the steps the model took.
    pub step: u32,
    /// The most steps the run may take so far. Going on after the limit adds a whole budget, so
    /// a run the person is still helping is not cut off again at once.
    pub step_limit: u32,
    /// Set once a step ended the run.
    pub finished: bool,
    /// The model's own notes to itself, carried from step to step and shown with each look.
    pub memo: String,
    /// What the models have cost the run so far.
    pub usage: Usage,
    /// Things the model is told on its next look, about what its plan did.
    pub notes: Vec<String>,
    /// The run's history of turns, folded and compacted as it grows.
    pub memory: Memory,
    /// Results of actions sent since the model last looked, which may be several batches.
    pub carried: Vec<ActionResult>,
    /// The previous screenshot's signature, for telling whether the page changed.
    pub last_signature: Option<Signature>,
    /// Steps in a row where the screen did not change.
    pub stale: u32,
    /// Model steps in a row whose every action failed the same way, and that failure. A plan
    /// refused whole, step after step, is a loop the model cannot see out of.
    pub failed_streak: u32,
    pub last_failure: String,
}

impl Session {
    pub fn new(task: Task, profile: Profile) -> Self {
        let step_limit = task.persistence.max_steps;
        Session {
            id: new_id(),
            task,
            profile,
            created: SystemTime::now(),
            touched: Instant::now(),
            seq: 0,
            step: 0,
            step_limit,
            finished: false,
            memo: String::new(),
            usage: Usage::default(),
            notes: Vec::new(),
            memory: Memory::default(),
            carried: Vec::new(),
            last_signature: None,
            stale: 0,
            failed_streak: 0,
            last_failure: String::new(),
        }
    }

    /// Lets a run that reached its limit go on with a whole budget more.
    pub fn extend(&mut self) {
        self.step_limit += self.task.persistence.max_steps;
        self.finished = false;
    }

    /// Whether the run has used its steps.
    pub fn at_step_limit(&self) -> bool {
        self.step >= self.step_limit
    }

    pub fn touch(&mut self) {
        self.touched = Instant::now();
    }
}

/// A fresh id: 128 bits from the standard library's randomly keyed hasher, as hex.
fn new_id() -> String {
    let a = RandomState::new().build_hasher().finish();
    let b = RandomState::new().build_hasher().finish();
    format!("{a:016x}{b:016x}")
}
