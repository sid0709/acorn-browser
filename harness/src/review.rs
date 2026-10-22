//! Reviewing what a plan filled in, on the side, so nothing waits for it.
//!
//! A plan made from a survey is carried out zone by zone: a zone is the actions whose points were
//! measured on one screen of the survey. When the last action of a zone is done the browser takes
//! a photo of the page. The decision model is asked, for each field the plan filled in that zone,
//! whether the field shows what was typed into it, while the next zone is being carried out; a
//! photo that comes with the next look instead is reviewed then. What the reviews found wrong is
//! told to the model once, with the survey that follows, to put right in one answer; the rest of
//! the plan is not carried out past it, since it would go on to send what is wrong.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::action::{self, Action, Kind};
use crate::change;
use crate::model;
use crate::observe::{Observation, Viewport, ZoneShot};
use crate::ports::{Decider, Decision, Part, Question, Usage};
use crate::prompt;
use crate::run::{Agent, StepError};
use crate::session::Session;
use crate::todo::FieldStatus;
use crate::trace::ModelCall;

/// The most characters of a value a review asks about.
pub const MAX_EXPECT_CHARS: usize = 120;
/// The most zone photos one look may carry.
pub const MAX_ZONE_SHOTS: usize = 64;
/// Below this probability of yes, a field is more likely wrong than right, and is told to the
/// model as wrong. There is no tunable cutoff.
pub const LIKELY: f64 = 0.5;
/// The start of the key of the question about the n-th field of a zone: `e1`, `e2`, ...
const ASK_EXPECT_PREFIX: &str = "e";

/// What a field of the plan should show once the plan has been carried out: the field is known by
/// its label, as the model wrote it.
#[derive(Clone, Debug, PartialEq)]
pub struct Expectation {
    pub label: String,
    pub value: String,
    /// Where the plan's point for the field lies on the page (screenshot pixels from its top).
    pub y: f64,
}

/// The review of one zone.
#[derive(Clone, Debug, Default)]
pub struct ReviewResult {
    pub zone: u32,
    /// The plan whose zone it reviewed.
    pub plan_gen: u32,
    /// The fields the review asked about, and those it found not showing what was planned.
    pub asked: Vec<Expectation>,
    pub failed: Vec<Expectation>,
    pub usage: Usage,
    pub error: Option<String>,
    /// The call, for the trace.
    pub call: ModelCall,
}

/// What the browser does with the rest of its batch once a zone's photo is taken in.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AfterShot {
    /// Carry on with the batch.
    #[default]
    GoOn,
    /// Stop the batch and send the next look: a field filled earlier in it was found wrong, and
    /// the model must see the page before the plan goes on.
    Abort,
}

/// What a session keeps for the reviews running beside its plan. Shared with the threads that
/// run them, so a look never waits on a review beyond the moment it chooses to.
#[derive(Debug, Default)]
pub struct Reviews {
    state: Mutex<ReviewState>,
    /// Signalled when a review ends.
    ended: Condvar,
}

#[derive(Debug, Default)]
struct ReviewState {
    running: usize,
    done: Vec<ReviewResult>,
    /// The zones of each plan that have a review, so a photo that comes twice (mid-batch and
    /// again with the look) is reviewed once.
    started: BTreeSet<(u32, u32)>,
    /// Counts what a waiter may care about: a review that ended, the to-do list that changed.
    changes: u64,
}

impl Reviews {
    /// Marks the review of a zone of a plan as running, unless it already has one.
    fn begin(&self, plan_gen: u32, zone: u32) -> bool {
        let mut state = self.state.lock().unwrap();
        if !state.started.insert((plan_gen, zone)) {
            return false;
        }
        state.running += 1;
        true
    }

    /// Keeps a review that ended and wakes whoever waits for it.
    fn finished(&self, result: ReviewResult) {
        let mut state = self.state.lock().unwrap();
        state.running = state.running.saturating_sub(1);
        state.done.push(result);
        state.changes += 1;
        self.ended.notify_all();
    }

    /// Counts a change to what the reviews feed (the to-do list) and wakes whoever waits for one.
    pub(crate) fn wake(&self) {
        let mut state = self.state.lock().unwrap();
        state.changes += 1;
        self.ended.notify_all();
    }

    /// How many changes there have been, to wait from.
    pub(crate) fn changes(&self) -> u64 {
        self.state.lock().unwrap().changes
    }

    /// Waits for a change past `since`, at most `timeout`, and says whether one came.
    pub(crate) fn wait_change(&self, since: u64, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut state = self.state.lock().unwrap();
        while state.changes <= since {
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            state = self.ended.wait_timeout(state, deadline - now).unwrap().0;
        }
        true
    }

    /// Waits for the running reviews, at most `timeout`, and says whether they all ended.
    fn wait_all(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut state = self.state.lock().unwrap();
        while state.running > 0 {
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            state = self.ended.wait_timeout(state, deadline - now).unwrap().0;
        }
        true
    }

    /// The reviews that ended since the last take.
    pub(crate) fn take(&self) -> Vec<ReviewResult> {
        std::mem::take(&mut self.state.lock().unwrap().done)
    }

    /// Whether a review of this plan that ended, and was not taken in yet, found a field wrong.
    fn found_wrong(&self, plan_gen: u32) -> bool {
        self.state.lock().unwrap().done.iter().any(|result| result.plan_gen == plan_gen && !result.failed.is_empty())
    }
}

/// What the plan fills in, by zone: a field the plan clicked on (the point has a label) and typed
/// into. A secret is not asked about. A field the plan fills more than once is asked about for
/// the last value only: that is what it should show.
pub fn expectations_of(planned: &[Action], obs: &Observation) -> BTreeMap<u32, Vec<Expectation>> {
    let mut out: BTreeMap<u32, Vec<Expectation>> = BTreeMap::new();
    let mut label = String::new();
    let mut y = 0.0;
    for action in planned {
        if let Some(point) = action.point() {
            label = action.label.trim().to_string();
            y = action.scroll_to.unwrap_or(obs.viewport.scroll_y) + point.y;
            continue;
        }
        if let Kind::Type { text, secret: false } = &action.kind
            && action.zone > 0
            && !label.is_empty()
            && !text.trim().is_empty()
        {
            let exp = Expectation { label: std::mem::take(&mut label), value: model::clip_text(text.trim(), MAX_EXPECT_CHARS), y };
            let zone = out.entry(action.zone).or_default();
            match zone.iter_mut().find(|had| action::labels_agree(&had.label, &exp.label)) {
                Some(had) => *had = exp,
                None => zone.push(exp),
            }
        }
    }
    out
}

/// Asks whether the field with a label shows the planned answer. The answer is matched by what it
/// means, not letter for letter: a dropdown shows the option chosen, and the page's wording of it
/// may be longer than or differ from the model's ("No, never" for "No").
fn expect_question(exp: &Expectation) -> Question {
    Question::yes_no(format!(
        "Does the field labelled {:?} show an answer that means {:?}? A dropdown shows the option chosen, and its wording may be longer than or differ from the answer as long as it says the same thing; a box that takes several choices shows each as a tag, and the one asked about among them is enough. A field whose answer is not settled does not show it: a list of suggestions or options still open under or over the field, a highlighted suggestion waiting to be chosen, or a sign that the field is still loading or searching means no choice has been made yet, whatever text sits in the box. Answer no if the field is empty, shows a different answer, is not settled, or shows an error.",
        exp.label, exp.value
    ))
}

fn expect_key(n: usize) -> String {
    format!("{ASK_EXPECT_PREFIX}{n}")
}

/// Whether a zone photo is an image the size of the page's window.
pub fn fits_viewport(shot: &ZoneShot, viewport: &Viewport) -> bool {
    match change::image_size(&shot.screenshot) {
        Ok((width, height)) => width.abs_diff(viewport.width) <= change::SIZE_TOLERANCE && height.abs_diff(viewport.height) <= change::SIZE_TOLERANCE,
        Err(_) => false,
    }
}

/// The photos of a look that are usable: an image the size of the viewport, at most
/// [`MAX_ZONE_SHOTS`] of them. A photo that is not is dropped, not a reason to refuse the look:
/// the run goes on and the whole page is looked at again after the plan.
pub fn accept_zone_shots(obs: &Observation) -> Vec<ZoneShot> {
    obs.zone_shots.iter().filter(|shot| fits_viewport(shot, &obs.viewport)).take(MAX_ZONE_SHOTS).cloned().collect()
}

impl Agent {
    /// Whether the zones of this run are reviewed: its plans are made from a survey, and a checker
    /// is on.
    pub(crate) fn reviews_on(&self, s: &Session) -> bool {
        s.task.survey && self.checks_on(s)
    }

    /// Takes a photo of a zone the browser sent while a batch is still being carried out, so its
    /// review runs while the next zone is, and says whether the batch goes on. A photo that is
    /// not an image the size of the page's window is dropped: the run goes on, and the page is
    /// looked at again after the plan.
    pub fn receive_shot(&self, id: &str, shot: ZoneShot) -> Result<AfterShot, StepError> {
        let session = self.session(id).ok_or(StepError::NoSession)?;
        let mut s = session.lock().unwrap();
        s.touch();
        if s.viewport.has_size() && !fits_viewport(&shot, &s.viewport) {
            return Ok(AfterShot::GoOn);
        }
        self.start_review(&mut s, shot);
        // A field filled earlier in the batch was found wrong: the rest of the batch would go on
        // to send what is wrong, so it stops, and the model looks at the page first.
        if s.reviews.found_wrong(s.plan_gen) || s.reviewed.values().any(|ok| !ok) {
            return Ok(AfterShot::Abort);
        }
        Ok(AfterShot::GoOn)
    }

    /// Starts the review of a zone's photo on its own thread, unless the zone has one: the fields
    /// the plan typed into in that zone. The session is locked.
    pub(crate) fn start_review(&self, s: &mut Session, shot: ZoneShot) {
        // The photo is of the page as the plan left it: a settled stretch that no longer looks as
        // it did is settled no more.
        if let Ok((signature, _, _)) = change::signature(&shot.screenshot) {
            s.check_settled(shot.scroll_y, s.viewport.height, &signature);
        }
        if !self.reviews_on(s) {
            return;
        }
        let Some(decider) = self.decider.clone() else { return };
        let exps = s.expect.get(&shot.zone).cloned().unwrap_or_default();
        if exps.is_empty() || !s.reviews.begin(s.plan_gen, shot.zone) {
            return;
        }
        let reviews = s.reviews.clone();
        let plan_gen = s.plan_gen;
        let zone = shot.zone;
        let asked = exps.clone();
        let spawned = std::thread::Builder::new().name("review".to_string()).spawn({
            let reviews = reviews.clone();
            move || reviews.finished(review_zone(decider.as_ref(), shot, exps, plan_gen))
        });
        if let Err(err) = spawned {
            reviews.finished(ReviewResult { zone, plan_gen, asked, error: Some(format!("no thread for the review: {err}")), ..Default::default() });
        }
    }

    /// Waits a little for the reviews still running, then takes in every finished one: what they
    /// found wrong is told to the model, and the next look is a survey so it can put it right. A
    /// review still running is picked up at the next look. The session is locked.
    pub(crate) fn collect_reviews(&self, s: &mut Session) {
        s.reviews.wait_all(self.config.review_wait);
        for result in s.reviews.take() {
            s.apply_review(result);
        }
        let wrong = std::mem::take(&mut s.review_wrong);
        if wrong.is_empty() {
            return;
        }
        let mut note = format!(
            "The harness looked at each part of the page right after it was filled in and found {} that {} not show what was planned: {}. Put them right in one answer; the screenshots you are given show the page as it is.",
            prompt::count(wrong.len(), "field"),
            if wrong.len() == 1 { "does" } else { "do" },
            wrong.join("; ")
        );
        // The plan does not go on past a wrong fill: its next batches would send what is wrong.
        // The model looks first; the results say what of the last batch ran.
        if !s.verify.is_empty() {
            s.plan.clear();
            s.verify.clear();
            note.push_str(" The rest of your plan was not carried out.");
        }
        s.notes.push(note);
        s.survey_again = true;
    }
}

/// Asks the decision model about every field of a zone, in one call.
fn review_zone(decider: &(dyn Decider + Send + Sync), shot: ZoneShot, exps: Vec<Expectation>, plan_gen: u32) -> ReviewResult {
    let questions = exps.iter().enumerate().map(|(i, exp)| (expect_key(i + 1), expect_question(exp))).collect();
    let state = vec![Part::Text("A screenshot of part of a page that has just been filled in.".to_string()), Part::Image(shot.screenshot)];
    let mut result = ReviewResult { zone: shot.zone, plan_gen, asked: exps.clone(), ..Default::default() };
    let labels: Vec<String> = exps.iter().enumerate().map(|(i, exp)| format!("{} {:?}", i + 1, exp.label)).collect();
    let started = std::time::SystemTime::now();
    let answered = decider.decide(Decision { state, questions });
    result.call = ModelCall::decision(&format!("what zone {} shows: {}", shot.zone, labels.join(", ")), answered.as_ref(), started);
    match answered {
        Ok(verdicts) => {
            result.usage = verdicts.usage;
            for (i, exp) in exps.into_iter().enumerate() {
                // A field more likely wrong than right is told to the model.
                if verdicts.yes(&expect_key(i + 1)).is_some_and(|p| p < LIKELY) {
                    result.failed.push(exp);
                }
            }
        }
        Err(err) => result.error = Some(err.to_string()),
    }
    result
}

impl Session {
    /// Takes one finished review into the run: its cost, the zone's standing, and the to-do list,
    /// where a field found not showing what was planned goes back to empty and the rest are
    /// ticked off. What it found wrong is kept for the note of the next look. A review that
    /// failed found nothing: the survey that follows shows the zone.
    pub(crate) fn apply_review(&mut self, mut result: ReviewResult) {
        self.usage.add(result.usage);
        self.pending_calls.push(std::mem::take(&mut result.call));
        if result.plan_gen == self.plan_gen {
            self.reviewed.insert(result.zone, result.error.is_none() && result.failed.is_empty());
        }
        if result.error.is_some() {
            return;
        }
        for exp in &result.failed {
            self.review_wrong.push(format!("{:?} does not show {:?} (screen {})", exp.label, exp.value, result.zone));
            self.set_field(&exp.label, FieldStatus::Empty);
            self.unverified(&exp.label, exp.y);
        }
        // What the zone's review did not fault, it confirmed: those fields are ticked off the
        // to-do list, and will settle their rows.
        for exp in &result.asked {
            if result.failed.iter().any(|bad| bad.label == exp.label) {
                continue;
            }
            // A review that comes back after the run left the page confirms nothing on the page
            // it is on now.
            if self.expect_url == self.confirmed_url {
                self.confirmed.push(exp.label.clone());
            }
            self.set_field(&exp.label, FieldStatus::Filled);
        }
    }

    /// Notes the page a look is of: what the reviews confirmed is of the page they were on.
    pub(crate) fn see_page(&mut self, url: &str) {
        let url = crate::observe::without_fragment(url);
        if self.confirmed_url != url {
            self.confirmed.clear();
            self.confirmed_url = url.to_string();
            self.held_reserved = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::observe::SurveyScreen;
    use crate::profile::Profile;
    use crate::run::Config;
    use crate::task::Task;
    use crate::testing::{Replying, Sure, look};
    use crate::verify::ASK_MATCHES;

    #[test]
    fn a_plan_expects_each_typed_field_to_show_its_last_value() {
        let obs = Observation { viewport: Viewport { scroll_y: 100.0, ..Default::default() }, ..Default::default() };
        let mut name = Action::new("a1", Kind::Click { x: 10.0, y: 20.0 });
        name.label = "Full name".into();
        name.zone = 1;
        let mut typed = Action::new("a2", Kind::Type { text: " A. Person ".into(), secret: false });
        typed.zone = 1;
        let mut again = Action::new("a4", Kind::Type { text: "B. Person".into(), secret: false });
        again.zone = 1;
        let mut secret = Action::new("a6", Kind::Type { text: "hunter2".into(), secret: true });
        secret.zone = 2;
        let mut pass = name.clone();
        pass.label = "Password".into();
        pass.zone = 2;
        let exps = expectations_of(&[name.clone(), typed, name, again, pass, secret], &obs);
        assert_eq!(exps.get(&1), Some(&vec![Expectation { label: "Full name".into(), value: "B. Person".into(), y: 120.0 }]));
        assert!(exps.get(&2).is_none());
    }

    #[test]
    fn a_review_that_finds_a_field_wrong_tells_the_model_and_asks_for_a_survey() {
        let reply = r#"{"status":"working","message":"Filling.","actions":[
            {"kind":"click","screen":1,"x":10,"y":10,"label":"Name"},
            {"kind":"type","text":"A. Person","check":"Name shows A. Person"}]}"#;
        let (model, seen) = Replying::new(reply);
        let agent = Agent::new(Config::default(), model).with_decider(Sure::of(&[(ASK_MATCHES, 1.0)]));
        let id = agent.start(Task::new("fill the form"), Profile::default());
        let mut survey = look(false, &[]);
        survey.survey = vec![SurveyScreen { screenshot: survey.screenshot.clone(), scroll_y: 0.0 }];
        let first = agent.step(&id, survey).unwrap();
        assert_eq!(first.actions.len(), 2);
        assert_eq!(first.actions[1].zone, 1);
        // The photo of the zone comes with the next look; its review finds the name not shown.
        let mut second = look(true, &["s1a1", "s1a2"]);
        second.zone_shots = vec![ZoneShot { zone: 1, screenshot: second.screenshot.clone(), scroll_y: 0.0 }];
        let step = agent.step(&id, second).unwrap();
        assert_eq!(step.number, 2);
        assert!(step.survey);
        let seen = seen.lock().unwrap();
        assert!(seen[1].contains("found 1 field that does not show what was planned: \"Name\" does not show \"A. Person\" (screen 1)"), "{}", seen[1]);
    }

    #[test]
    fn a_wrong_fill_found_mid_batch_stops_the_batch_and_the_rest_of_the_plan() {
        let reply = r#"{"status":"working","message":"Filling.","actions":[
            {"kind":"click","screen":1,"x":10,"y":10,"label":"Name"},{"kind":"type","text":"A. Person","check":"Name shows A. Person"},
            {"kind":"click","screen":2,"x":10,"y":10,"label":"Email"},{"kind":"type","text":"a@b.c","check":"Email shows a@b.c"},
            {"kind":"click","screen":2,"x":10,"y":40,"label":"Send","commit":"send","check":"a thank-you"}]}"#;
        let (model, seen) = Replying::new(reply);
        let agent = Agent::new(Config::default(), model).with_decider(Sure::of(&[(ASK_MATCHES, 1.0)]));
        let task = Task::new("fill the form").allow(crate::task::Irreversible::Send, crate::task::Allowance::Auto);
        let id = agent.start(task, Profile::default());
        let mut survey = look(false, &[]);
        let screen = SurveyScreen { screenshot: survey.screenshot.clone(), scroll_y: 0.0 };
        survey.survey = vec![screen.clone(), screen];
        let first = agent.step(&id, survey).unwrap();
        // The whole page is one batch checked once, the send in it: a wrong fill found while the
        // batch runs must stop it before the send.
        assert_eq!(first.actions.len(), 5);
        let shot = |zone| ZoneShot { zone, screenshot: look(true, &[]).screenshot, scroll_y: 0.0 };
        assert_eq!(agent.receive_shot(&id, shot(1)).unwrap(), AfterShot::GoOn);
        agent.session(&id).unwrap().lock().unwrap().reviews.wait_all(Duration::from_secs(5));
        assert_eq!(agent.receive_shot(&id, shot(2)).unwrap(), AfterShot::Abort);
        let step = agent.step(&id, look(true, &["s1a1", "s1a2"])).unwrap();
        assert_eq!(step.number, 2);
        assert!(step.survey);
        let seen = seen.lock().unwrap();
        assert!(seen[1].contains("found 2 fields that do not show what was planned: \"Name\" does not show \"A. Person\" (screen 1); \"Email\""), "{}", seen[1]);
        assert!(seen[1].contains("show the page as it is. The rest of your plan was not carried out."), "{}", seen[1]);
    }
}
