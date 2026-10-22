//! The run's own list of what the task needs: the form's to-do list, read from the pictures.
//!
//! On every survey the model lists each question it sees, where it is and whether it is answered;
//! the run keeps that list for the page, the reviews of the zones (the decision model reading the
//! photo of each part right after it was filled) tick a field off or put it back, and the next
//! survey replaces the list with what the model reads then. What the list says will drive the
//! gates too: a stop or a send is held for the fields the model read as empty. Each survey the
//! model is shown carries the list back to it, every field with the screen of that survey it lies
//! on, so it sees what is left and where, and puts its reading right.

use serde::{Deserialize, Serialize};

use crate::model::Reply;
use crate::observe::{Observation, without_fragment};
use crate::session::Session;

/// What the model says of a field's state: answered, required and still without an answer,
/// optional and left blank (it holds nothing back), or the person's own to give.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FieldStatus {
    Filled,
    #[default]
    Empty,
    Optional,
    NeedsPerson,
}

impl FieldStatus {
    /// The state the model named; anything else is empty.
    pub fn parse(state: &str) -> FieldStatus {
        match state.trim() {
            "filled" => FieldStatus::Filled,
            "optional" => FieldStatus::Optional,
            "needs_person" => FieldStatus::NeedsPerson,
            _ => FieldStatus::Empty,
        }
    }

    fn name(self) -> &'static str {
        match self {
            FieldStatus::Filled => "filled",
            FieldStatus::Empty => "empty",
            FieldStatus::Optional => "optional",
            FieldStatus::NeedsPerson => "needs_person",
        }
    }
}

/// One question of the form: its label as the page writes it, where it is (screenshot pixels
/// from the page's top), and its state.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FieldState {
    pub label: String,
    pub y: f64,
    pub state: FieldStatus,
}

impl Session {
    /// Replaces the page's list with what the model read on this survey.
    pub(crate) fn note_fields(&mut self, reply: &Reply, obs: &Observation) {
        let Some(raw) = &reply.fields else { return };
        if obs.survey.is_empty() {
            return;
        }
        let mut fields = Vec::new();
        for field in raw {
            let label = field.label.trim();
            let (Some(screen), Some(y)) = (field.screen, field.y) else { continue };
            let Some(on) = screen.checked_sub(1).and_then(|i| obs.survey.get(i as usize)) else { continue };
            if label.is_empty() {
                continue;
            }
            fields.push(FieldState { label: label.to_string(), y: on.scroll_y + y, state: FieldStatus::parse(&field.state) });
        }
        self.fields = fields;
        self.fields_url = without_fragment(&obs.url).to_string();
        self.fields_changed = true;
    }

    /// The list for the page being looked at; empty for another page.
    pub fn fields_on(&self, url: &str) -> &[FieldState] {
        if self.fields_url != without_fragment(url) { &[] } else { &self.fields }
    }

    /// The fields the model read as empty on the page, by label.
    pub fn empty_fields_on(&self, url: &str) -> Vec<&str> {
        self.fields_on(url).iter().filter(|f| f.state == FieldStatus::Empty).map(|f| f.label.as_str()).collect()
    }

    /// The list to send with the answer when it changed, and forgets that it changed.
    pub(crate) fn take_fields(&mut self) -> Vec<FieldState> {
        if !self.fields_changed {
            return Vec::new();
        }
        self.fields_changed = false;
        self.fields.clone()
    }

    /// Tells the model its own to-do list of the page with a survey: each field, the screen it
    /// lies on, and its state as it read it and the reviews of the photos corrected it. Empty when
    /// there is no list for the page, or the look is no survey.
    pub(crate) fn fields_note(&self, obs: &Observation) -> String {
        let fields = self.fields_on(&obs.url);
        if fields.is_empty() || obs.survey.is_empty() {
            return String::new();
        }
        let parts: Vec<String> = fields
            .iter()
            .map(|f| {
                let r#where = match screen_of(f.y, obs) {
                    0 => "not in this survey".to_string(),
                    n => format!("screen {n}"),
                };
                format!("[{where}] {:?}: {}", f.label, f.state.name())
            })
            .collect();
        format!(
            "Your to-do list of this page, as you read it on your last survey and the photos of each part corrected it: {}. It is your last reading, not the page: judge each field by the screenshots you are given now, fill what is empty, and list every field in \"fields\" as you read it now. A field is filled when its box shows an answer, whatever message lies beside it.",
            parts.join("; ")
        )
    }
}

/// The number (from 1) of the survey screen a place on the page lies on, the one it lies most
/// inside of where screens overlap; 0 when no screen of the survey holds it.
pub fn screen_of(y: f64, obs: &Observation) -> u32 {
    let height = obs.viewport.height as f64;
    let mut best = 0;
    let mut room = -1.0;
    for (i, screen) in obs.survey.iter().enumerate() {
        if y < screen.scroll_y || y > screen.scroll_y + height {
            continue;
        }
        let inside = (y - screen.scroll_y).min(screen.scroll_y + height - y);
        if inside > room {
            best = i as u32 + 1;
            room = inside;
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::observe::SurveyScreen;
    use crate::profile::Profile;
    use crate::run::{Agent, Config};
    use crate::task::Task;
    use crate::testing::{Replying, look};

    #[test]
    fn the_list_read_on_a_survey_is_kept_sent_and_shown_back_on_the_next_survey() {
        let reply = r#"{"status":"working","message":"","fields":[{"label":"Name","screen":1,"y":30,"state":"filled"},{"label":"Email","screen":2,"y":20,"state":"empty"},{"label":"","screen":1,"y":1,"state":"empty"}],"actions":[{"kind":"wait","ms":100}]}"#;
        let (model, seen) = Replying::new(reply);
        let agent = Agent::new(Config { max_stale: 100, ..Config::default() }, model);
        let id = agent.start(Task::new("fill the form"), Profile::default());
        let survey = || {
            let mut obs = look(false, &[]);
            obs.survey = vec![SurveyScreen { screenshot: obs.screenshot.clone(), scroll_y: 0.0 }, SurveyScreen { screenshot: obs.screenshot.clone(), scroll_y: 500.0 }];
            obs
        };
        let first = agent.step(&id, survey()).unwrap();
        assert_eq!(
            first.fields,
            vec![FieldState { label: "Name".into(), y: 30.0, state: FieldStatus::Filled }, FieldState { label: "Email".into(), y: 520.0, state: FieldStatus::Empty }]
        );
        let second = agent.step(&id, survey()).unwrap();
        assert_eq!(second.fields.len(), 2);
        let seen = seen.lock().unwrap();
        assert!(!seen[0].contains("to-do list"));
        assert!(seen[1].contains("Your to-do list of this page, as you read it on your last survey and the photos of each part corrected it: [screen 1] \"Name\": filled; [screen 2] \"Email\": empty."), "{}", seen[1]);
    }
}
