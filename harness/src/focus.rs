//! A click that lands beside its control (in the gap of a bordered box, on the wrapper a page
//! draws round an input) gives nothing focus, and what was to be typed reaches no control. Told
//! only that nothing had focus, a model plans the same point again a few pixels off: a recorded
//! run did so nine times on a phone box, with a survey and a model call each time. So when typing
//! or a key reached nothing after a click that went through, the model is told where it clicked
//! and how to aim, and the field is one whose fill did not verify: the survey that follows owes
//! it a screen where it is whole. The step names where such fields lie (`Step::survey_focus`),
//! and the browser adds a screen centred on one that no screen of its survey shows clear of the
//! window's edges.

use std::collections::HashMap;

use crate::action::{Action, Kind};
use crate::observe::{ActionResult, without_fragment};
use crate::session::Session;

/// How close (screenshot pixels) two places to keep whole may be and count as one.
pub const SURVEY_FOCUS_PX: f64 = 24.0;

/// A field whose fill did not verify: its label, as the plan named it, and where it lies on the
/// page (screenshot pixels from its top).
#[derive(Clone, Debug, PartialEq)]
pub struct FocusTarget {
    pub label: String,
    pub y: f64,
}

/// One note per typed action or key that reached no control after a click that went through:
/// where the click was and how to aim. `by_id` is the plan by action id.
pub fn unreached_notes(results: &[ActionResult], by_id: &HashMap<String, Action>) -> Vec<String> {
    let mut notes = Vec::new();
    let mut reached: Option<&Action> = None;
    for result in results {
        let Some(action) = by_id.get(&result.id) else { continue };
        if action.point().is_some() {
            reached = result.ok.then_some(action);
            continue;
        }
        let typed = matches!(action.kind, Kind::Type { .. } | Kind::Key { .. });
        if (result.ok && !result.unreached) || !typed {
            continue;
        }
        if let Some(click) = reached.take() {
            notes.push(unreached_note(click, action));
        }
    }
    notes
}

/// The note for one click that reached no control.
fn unreached_note(click: &Action, failed: &Action) -> String {
    let point = click.point().unwrap_or_default();
    let label = if click.label.trim().is_empty() { "a control".to_string() } else { format!("for {:?}", click.label.trim()) };
    let screen = if click.zone > 0 { format!(" on screen {}", click.zone) } else { String::new() };
    let what = match &failed.kind {
        Kind::Key { keys } => format!("pressing {keys}"),
        Kind::Type { secret: true, .. } => "the typing".to_string(),
        Kind::Type { text, .. } => format!("typing {text:?}"),
        _ => "what followed".to_string(),
    };
    format!(
        "The click {label} at ({:.0}, {:.0}){screen} went through, but no control took focus there, so {what} was not done. A point beside a box, on its label, or on the wrapper a page draws round an input gives nothing focus: look at the screenshot and aim inside the box's edges, at the middle of its value line.",
        point.x, point.y
    )
}

impl Session {
    /// Records a field whose fill did not verify, at where it lies on the page. The next look is
    /// a survey, with a screen where the field is whole.
    pub(crate) fn unverified(&mut self, label: &str, y: f64) {
        let label = label.trim();
        if label.is_empty() || y <= 0.0 {
            return;
        }
        self.retry.push(FocusTarget { label: label.to_string(), y });
        self.survey_again = true;
    }

    /// Records the fields whose typing found nothing to type into after their click went through:
    /// the click missed the box.
    pub(crate) fn note_unreached_fields(&mut self, results: &[ActionResult]) {
        let mut reached: Option<Action> = None;
        for result in results {
            let Some(action) = self.by_id.get(&result.id) else { continue };
            if action.point().is_some() {
                reached = result.ok.then(|| action.clone());
                continue;
            }
            if (result.ok && !result.unreached) || !matches!(action.kind, Kind::Type { .. }) {
                continue;
            }
            if let Some(click) = reached.take() {
                let top = click.scroll_to.unwrap_or(self.plan_scroll_y);
                self.unverified(&click.label.clone(), top + click.point().map(|p| p.y).unwrap_or_default());
            }
        }
    }

    /// Where the fields still to fill lie on the page (screenshot pixels from its top), top to
    /// bottom, for the survey that follows to show each whole: the fields whose fill did not
    /// verify since the model last looked. Nothing on another page than the plan's.
    pub(crate) fn survey_focus(&mut self, url: &str) -> Vec<f64> {
        let mut ys: Vec<f64> = Vec::new();
        if self.expect_url == without_fragment(url) {
            ys.extend(self.retry.iter().map(|target| target.y));
        }
        self.retry.clear();
        ys.sort_by(f64::total_cmp);
        let mut out: Vec<f64> = Vec::new();
        for y in ys {
            if out.last().is_some_and(|last| (y - last).abs() <= SURVEY_FOCUS_PX) {
                continue;
            }
            out.push(y);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use crate::observe::SurveyScreen;
    use crate::profile::Profile;
    use crate::run::{Agent, Config};
    use crate::task::Task;
    use crate::testing::{Replying, Sure, look};
    use crate::verify::ASK_MATCHES;

    #[test]
    fn typing_that_reached_nothing_tells_the_model_where_it_clicked_and_focuses_the_survey() {
        let reply = r#"{"status":"working","message":"Filling.","actions":[{"kind":"click","screen":1,"x":10,"y":30,"label":"Phone"},{"kind":"type","text":"123"}]}"#;
        let (model, seen) = Replying::new(reply);
        let agent = Agent::new(Config::default(), model).with_decider(Sure::of(&[(ASK_MATCHES, 1.0), ("p1", 1.0)]));
        let id = agent.start(Task::new("fill the form"), Profile::default());
        let mut survey = look(false, &[]);
        survey.survey = vec![SurveyScreen { screenshot: survey.screenshot.clone(), scroll_y: 0.0 }];
        assert!(!agent.step(&id, survey).unwrap().survey);
        let mut second = look(true, &["s1a1"]);
        second.results[0].ok = true;
        second.results.push(crate::observe::ActionResult { id: "s1a2".into(), ok: false, unreached: true, error: "nothing has focus".into(), ..Default::default() });
        let step = agent.step(&id, second).unwrap();
        assert!(step.survey);
        assert_eq!(step.survey_focus, vec![30.0]);
        let seen = seen.lock().unwrap();
        assert!(seen[1].contains("The click for \"Phone\" at (10, 30) on screen 1 went through, but no control took focus there, so typing \"123\" was not done."), "{}", seen[1]);
    }
}
