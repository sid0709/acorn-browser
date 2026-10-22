//! The run's own list of what the task needs: the form's to-do list, read from the pictures.
//!
//! On every survey the model lists each question it sees, where it is and whether it is answered;
//! the run keeps that list for the page, the reviews of the zones (the decision model reading the
//! photo of each part right after it was filled) tick a field off or put it back, and the next
//! survey replaces the list with what the model reads then. What the list says will drive the
//! gates too: a stop or a send is held for the fields the model read as empty. Each survey the
//! model is shown carries the list back to it, every field with the screen of that survey it lies
//! on, so it sees what is left and where, and puts its reading right.

use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::action;
use crate::model::Reply;
use crate::observe::{Observation, without_fragment};
use crate::run::{Agent, StepError};
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
        self.bump_fields();
    }

    /// Puts a field of the list in a state, by the label the model used for it, when a review
    /// found it showing what was planned (filled) or not (empty).
    pub(crate) fn set_field(&mut self, label: &str, state: FieldStatus) {
        let mut changed = false;
        for field in &mut self.fields {
            if action::labels_agree(&field.label, label) && field.state != state {
                field.state = state;
                changed = true;
            }
        }
        if changed {
            self.bump_fields();
        }
    }

    /// Counts a change to the list, for the next answer and for a wait on it (`wait_fields`).
    fn bump_fields(&mut self) {
        self.fields_changed = true;
        self.fields_version += 1;
        self.reviews.wake();
    }

    /// The list for the page being looked at; empty for another page.
    pub fn fields_on(&self, url: &str) -> &[FieldState] {
        if self.fields_url != without_fragment(url) { &[] } else { &self.fields }
    }

    /// The fields the model read as empty on the page, by label.
    pub fn empty_fields_on(&self, url: &str) -> Vec<&str> {
        self.fields_on(url).iter().filter(|f| f.state == FieldStatus::Empty).map(|f| f.label.as_str()).collect()
    }

    /// Whether a field the model read as empty lies in a stretch of the page.
    pub(crate) fn empty_field_near(&self, url: &str, from: f64, to: f64) -> bool {
        self.fields_on(url).iter().any(|f| f.state == FieldStatus::Empty && f.y >= from && f.y <= to)
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

/// The to-do list as the run has it, with the count of its changes so far.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FieldsUpdate {
    pub version: u32,
    pub fields: Vec<FieldState>,
}

impl Agent {
    /// Answers with the to-do list once it has changed since `since` (its version count), or
    /// with the same version and no list when nothing changed within `timeout`. A review that
    /// ended is taken in first: that is what changes the list between looks, so a list shown to
    /// the person follows each zone's photo within about a second of its being read, instead of
    /// waiting for the next look. A run that is over ends the wait.
    pub fn wait_fields(&self, id: &str, since: u32, timeout: Duration) -> Result<FieldsUpdate, StepError> {
        let session = self.session(id).ok_or(StepError::NoSession)?;
        let deadline = Instant::now() + timeout;
        loop {
            let (reviews, changes, version) = {
                let mut s = session.lock().unwrap();
                if s.finished {
                    return Err(StepError::SessionOver);
                }
                for result in s.reviews.take() {
                    s.apply_review(result);
                }
                if s.fields_version > since {
                    return Ok(FieldsUpdate { version: s.fields_version, fields: s.fields.clone() });
                }
                (s.reviews.clone(), s.reviews.changes(), s.fields_version)
            };
            let now = Instant::now();
            if now >= deadline || !reviews.wait_change(changes, deadline - now) {
                return Ok(FieldsUpdate { version, fields: Vec::new() });
            }
        }
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
    use crate::observe::ZoneShot;
    use crate::testing::{Replying, Sure, look};
    use crate::verify::ASK_MATCHES;

    #[test]
    fn a_review_ticks_a_field_off_the_list_and_a_wait_sees_it() {
        let reply = r#"{"status":"working","message":"","fields":[{"label":"Name","screen":1,"y":10,"state":"empty"}],
            "actions":[{"kind":"click","screen":1,"x":10,"y":10,"label":"Name"},{"kind":"type","text":"A. Person","check":"Name shows A. Person"}]}"#;
        let (model, _) = Replying::new(reply);
        let agent = Agent::new(Config::default(), model).with_decider(Sure::of(&[(ASK_MATCHES, 1.0), ("p1", 1.0), ("e1", 1.0)]));
        let id = agent.start(Task::new("fill the form"), Profile::default());
        let mut survey = look(false, &[]);
        survey.survey = vec![SurveyScreen { screenshot: survey.screenshot.clone(), scroll_y: 0.0 }];
        let first = agent.step(&id, survey).unwrap();
        assert_eq!(first.fields[0].state, FieldStatus::Empty);
        let version = agent.wait_fields(&id, 0, Duration::from_millis(10)).unwrap().version;
        assert!(version >= 1);
        // The zone's photo comes mid-batch; its review confirms the name, and the list follows.
        agent.receive_shot(&id, ZoneShot { zone: 1, screenshot: look(true, &[]).screenshot, scroll_y: 0.0 }).unwrap();
        let update = agent.wait_fields(&id, version, Duration::from_secs(5)).unwrap();
        assert_eq!(update.fields, vec![FieldState { label: "Name".into(), y: 10.0, state: FieldStatus::Filled }]);
        assert_eq!(agent.wait_fields(&id, update.version, Duration::from_millis(10)).unwrap().fields, vec![]);
    }

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
