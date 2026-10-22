//! What the person is told at the end: the outcome, what was inferred, what was not seen, and the
//! questions that piled up.
//!
//! A run's last line says how it went; the report says what to trust and what to finish. The
//! model lists, step by step, what it assumed for the person without being told; the run keeps
//! which parts of the page no look showed, which fields its to-do list still has open, and every
//! question it asked with the answer that came, if one did.

use serde::{Deserialize, Serialize};

use crate::map::Span;
use crate::ports::Usage;
use crate::run::{Agent, Question, Status, StepError, StopInfo};
use crate::session::Session;
use crate::todo::{FieldState, FieldStatus};

/// The most lines of assumptions a run keeps.
pub const MAX_ASSUMED: usize = 50;

/// The run's outcome for the person, with what they should know to trust it or finish it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub status: Status,
    /// The run's last line for the person.
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop: Option<StopInfo>,
    /// How many steps the model took, and what the models cost.
    pub steps: u32,
    pub usage: Usage,
    /// The facts and choices the model took for the person without being told, in its words.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub assumed: Vec<String>,
    /// The parts of the page the run ended on that no look showed (pixels from its top).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub not_seen: Vec<Span>,
    /// The fields of that page the to-do list still has open: empty, or the person's own to give.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub left: Vec<FieldState>,
    /// The questions asked of the person, with the answers that came.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub questions: Vec<Question>,
    /// The model's own notes at the end.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub memo: String,
}

impl Session {
    /// Keeps what the model says it assumed on a step, each line once.
    pub(crate) fn note_assumed(&mut self, lines: &[String]) {
        for line in lines {
            let line = line.trim();
            if line.is_empty() || self.assumed.iter().any(|had| had == line) || self.assumed.len() >= MAX_ASSUMED {
                continue;
            }
            self.assumed.push(line.to_string());
        }
    }

    /// The report as the run stands now.
    pub fn report(&self, status: Status, stop: Option<StopInfo>) -> Report {
        Report {
            status,
            message: if self.finished { self.stopped_for.clone() } else { self.message.clone() },
            stop,
            steps: self.step,
            usage: self.usage,
            assumed: self.assumed.clone(),
            not_seen: self.cover.gaps(),
            left: self.fields.iter().filter(|f| matches!(f.state, FieldStatus::Empty | FieldStatus::NeedsPerson)).cloned().collect(),
            questions: self.questions.clone(),
            memo: self.memo.clone(),
        }
    }
}

impl Agent {
    /// The report of a run as it stands: the whole picture at its end, or so far while it goes on.
    pub fn report(&self, id: &str) -> Result<Report, StepError> {
        let session = self.session(id).ok_or(StepError::NoSession)?;
        let s = session.lock().unwrap();
        let status = if s.finished { s.last_status } else { Status::Working };
        Ok(s.report(status, s.last_stop.clone()))
    }
}

#[cfg(test)]
mod tests {
    use crate::profile::Profile;
    use crate::run::{Agent, Config, Status};
    use crate::task::Task;
    use crate::testing::{Replying, look};

    #[test]
    fn the_end_report_carries_what_was_assumed_and_asked() {
        let reply = r#"{"status":"done","message":"Ordered.","assumed":["Chose standard delivery"," Chose standard delivery ","Left the gift note empty"],"question":"Did you want a gift note?","actions":[]}"#;
        let (model, _) = Replying::new(reply);
        let agent = Agent::new(Config::default(), model);
        let id = agent.start(Task::new("buy a kettle"), Profile::default());
        let step = agent.step(&id, look(false, &[])).unwrap();
        let report = step.report.unwrap();
        assert_eq!(report.status, Status::Done);
        assert_eq!(report.message, "Ordered.");
        assert_eq!(report.steps, 1);
        assert_eq!(report.assumed, vec!["Chose standard delivery", "Left the gift note empty"]);
        assert_eq!(report.questions.len(), 1);
        assert_eq!(agent.report(&id).unwrap(), report);
    }
}
