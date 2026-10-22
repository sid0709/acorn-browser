//! The one place between the model's reply and the browser where the harness may stop, change,
//! or question the plan. Starts as a pass-through; rules are added last.

use crate::action::Action;
use crate::model::Reply;
use crate::observe::Observation;
use crate::session::Session;

/// The gate. It may change the reply's status and message (a "done" the screen does not show
/// goes back to "working"), take actions out of the plan, and say why in `dropped`.
#[derive(Debug, Default)]
pub struct Gate;

impl Gate {
    /// Applies the rules. With none, the plan goes out as the model made it.
    pub fn apply(&self, _session: &mut Session, _obs: &Observation, _reply: &mut Reply, _planned: &mut Vec<Action>, _dropped: &mut Vec<String>) {}
}
