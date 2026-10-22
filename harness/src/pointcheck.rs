//! Checking the points of a plan against their labels before the plan is carried out.
//!
//! A model that plans a whole page names the survey screen of every point, and sometimes names
//! the wrong one: a recorded run put a name field on screen 7 when it was on screen 6, and typed
//! the person's name into another question. So before a plan made from a survey is carried out,
//! each point that has a label is checked against it: the screen is drawn with the points
//! numbered on it, and the decision model is asked, for each point, whether it is on the control
//! that belongs to its label. The screens are checked side by side, so it costs about one check.
//! The check never overrides the model: a point the checker doubts is acted on as planned, and
//! the model is told the doubt with its next look (a survey), so it checks what the point filled
//! and puts right what landed wrong. The driving model sees the screen; the checker only hurries
//! its correction.

use std::collections::BTreeSet;

use crate::action::Action;
use crate::mark;
use crate::observe::Observation;
use crate::ports::{Decider, Decision, Part, Question, Usage};
use crate::prompt;
use crate::review::LIKELY;
use crate::run::Agent;
use crate::session::Session;
use crate::trace::ModelCall;

/// The start of the key of the question about a numbered point: `p1`, `p2`, ...
const ASK_POINT_PREFIX: &str = "p";

fn point_key(n: usize) -> String {
    format!("{ASK_POINT_PREFIX}{n}")
}

/// Asks whether the point marked `n` is on the control the label belongs to.
fn point_question(n: usize, label: &str) -> Question {
    Question::yes_no(format!(
        "The red ring numbered {n}, with a dot at its middle, marks a point where something is about to be clicked or typed. Is that point on the control (the box, dropdown, checkbox or button) that belongs to the label {label:?}, or on that label itself? Answer no if it is on another question, on a heading, on plain text, or on empty space."
    ))
}

/// The point actions of a plan that can be checked, by zone: they have a label. Zones come in
/// the order of their first action.
fn checked_points(planned: &[Action]) -> Vec<(u32, Vec<Action>)> {
    let mut zones: Vec<(u32, Vec<Action>)> = Vec::new();
    for action in planned {
        if action.point().is_none() || action.label.trim().is_empty() {
            continue;
        }
        match zones.iter_mut().find(|(zone, _)| *zone == action.zone) {
            Some((_, actions)) => actions.push(action.clone()),
            None => zones.push((action.zone, vec![action.clone()])),
        }
    }
    zones
}

/// The survey screen of a zone (the single screenshot when there is no survey).
fn zone_image(obs: &Observation, zone: u32) -> &str {
    match zone {
        0 => &obs.screenshot,
        n => obs.survey.get(n as usize - 1).map(|screen| screen.screenshot.as_str()).unwrap_or(&obs.screenshot),
    }
}

/// What the check of one screen said: the probability that each point, by action id, is on its
/// control, and what the check cost.
#[derive(Debug, Default)]
struct ZoneCheck {
    verdicts: Vec<(String, f64)>,
    usage: Usage,
    call: ModelCall,
}

impl Agent {
    /// Checks every labelled point of a plan made from a survey against the screen the model said
    /// it is on. The plan runs whole; the points the checker doubts are told to the model with its
    /// next look. A check that cannot be made says nothing: the plan is not held up by a checker
    /// that is down.
    pub(crate) fn check_plan_points(&self, s: &mut Session, planned: &[Action], obs: &Observation) {
        if !s.task.survey || !self.checks_on(s) {
            return;
        }
        let Some(decider) = self.decider.as_ref() else { return };
        let zones = checked_points(planned);
        if zones.is_empty() {
            return;
        }
        let checks: Vec<ZoneCheck> = std::thread::scope(|scope| {
            let handles: Vec<_> = zones.iter().map(|(zone, actions)| scope.spawn(move || check_zone_points(decider.as_ref(), *zone, actions, obs))).collect();
            handles.into_iter().map(|handle| handle.join().unwrap_or_default()).collect()
        });
        let mut doubted = BTreeSet::new();
        for check in checks {
            s.usage.add(check.usage);
            s.pending_calls.push(check.call);
            doubted.extend(check.verdicts.into_iter().filter(|(_, p)| *p < LIKELY).map(|(id, _)| id));
        }
        if doubted.is_empty() {
            return;
        }
        s.notes.push(doubtful_points_note(planned, &doubted));
        s.survey_again = true;
    }
}

/// Asks the decision model about the labelled points on one screen.
fn check_zone_points(decider: &(dyn Decider + Send + Sync), zone: u32, actions: &[Action], obs: &Observation) -> ZoneCheck {
    let prompt = format!("points on screen {zone}: {}", actions.iter().enumerate().map(|(i, a)| format!("{} {:?}", i + 1, a.label)).collect::<Vec<_>>().join(", "));
    let Ok(marked) = mark::mark_screenshot(zone_image(obs, zone), actions) else {
        let call = ModelCall { kind: crate::trace::KIND_DECISION.to_string(), error: "the points could not be drawn".to_string(), ..Default::default() };
        return ZoneCheck { call, ..Default::default() };
    };
    let questions = actions.iter().enumerate().map(|(i, action)| (point_key(i + 1), point_question(i + 1, &action.label))).collect();
    let state = vec![
        Part::Text("A screenshot of a web page, with the points that are about to be clicked or typed at marked by numbered red rings.".to_string()),
        Part::Image(marked),
    ];
    let started = std::time::SystemTime::now();
    let answered = decider.decide(Decision { state, questions });
    let call = ModelCall::decision(&prompt, answered.as_ref(), started);
    match answered {
        Ok(verdicts) => ZoneCheck {
            verdicts: actions.iter().enumerate().filter_map(|(i, action)| verdicts.yes(&point_key(i + 1)).map(|p| (action.id.clone(), p))).collect(),
            usage: verdicts.usage,
            call,
        },
        Err(_) => ZoneCheck { call, ..Default::default() },
    }
}

/// Tells the model which points a checker doubted, in its own words, so it checks what they
/// filled on the survey that follows and puts right what landed wrong.
fn doubtful_points_note(planned: &[Action], doubted: &BTreeSet<String>) -> String {
    let lines: Vec<String> = planned.iter().filter(|action| doubted.contains(&action.id)).map(|action| format!("{:?} on screen {}", action.label, action.zone)).collect();
    format!(
        "A checker doubts that {} of your plan {} on the control named: {}. Look at the screens: if what you typed landed in another field, clear it and fill the right field by its label, with the right screen number.",
        prompt::count(lines.len(), "point"),
        if lines.len() == 1 { "is" } else { "are" },
        lines.join("; ")
    )
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
    fn a_doubted_point_is_told_to_the_model_and_the_next_look_is_a_survey() {
        let reply = r#"{"status":"working","message":"Filling.","actions":[{"kind":"click","screen":1,"x":10,"y":10,"label":"Name"},{"kind":"type","text":"A"}]}"#;
        let (model, seen) = Replying::new(reply);
        let agent = Agent::new(Config::default(), model).with_decider(Sure::of(&[(ASK_MATCHES, 1.0)]));
        let id = agent.start(Task::new("fill the form"), Profile::default());
        let mut survey = look(false, &[]);
        survey.survey = vec![SurveyScreen { screenshot: survey.screenshot.clone(), scroll_y: 0.0 }];
        let first = agent.step(&id, survey).unwrap();
        // The plan runs whole; the doubt only makes the next look a survey.
        assert_eq!(first.actions.len(), 2);
        assert!(first.survey);
        agent.step(&id, look(true, &["s1a1", "s1a2"])).unwrap();
        let seen = seen.lock().unwrap();
        assert!(seen[1].contains("A checker doubts that 1 point of your plan is on the control named: \"Name\" on screen 1."), "{}", seen[1]);
    }
}
