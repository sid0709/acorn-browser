//! A general-purpose agent harness for a browser that does any task given in chat.
//!
//! The model plans and recovers; the harness observes, verifies, remembers, and decides
//! when the run is done, stuck, or needs the person. One step of the run:
//!
//! ```text
//! observe -> stall check -> intervene -> memory -> model -> gate -> act -> verify -> todo/map
//! ```

pub mod action;
pub mod change;
pub mod gate;
pub mod map;
pub mod memory;
pub mod model;
pub mod observe;
pub mod openrouter;
pub mod ports;
pub mod profile;
pub mod prompt;
pub mod recover;
pub mod report;
pub mod review;
pub mod run;
pub mod session;
pub mod task;
#[cfg(test)]
pub(crate) mod testing;
pub mod todo;
pub mod trace;
pub mod verify;
