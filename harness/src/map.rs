//! Where the run has been on the page: the stretches the model settled, which need no second
//! look, and what it has and has not looked at.
//!
//! A page is looked at more than once, and most of it does not change: a description, a heading,
//! a part that is filled and right. When the model has looked at a screen of a survey and says it
//! will not need to come back to it, the screen is settled. Settled parts are painted blue on a
//! map of the page the person sees, are not shown to the model again, and are not scrolled to
//! and photographed again in the next survey. They stay settled while the page is the same page
//! and as tall as it was.
//!
//! The model sees one screen at a time, so it cannot know what a long page holds above or below
//! the screen. The run keeps, in screenshot pixels from the top of the page, which parts of it
//! have been on screen, and the model is told which have not: a required question in a part
//! nobody looked at is how a form is sent half empty. Pixels, not a share of the page: the page
//! grows as it is filled in (messages appear), and a percentage would shift under the run.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::action::{Action, Kind};
use crate::observe::{Observation, Viewport, without_fragment};
use crate::session::Session;

/// How much taller or shorter than when a part was settled, or looked at, the page may be
/// (screenshot pixels) before what was settled is forgotten, or what was looked at is not
/// trusted: a page that grew may have moved it.
pub const HEIGHT_TOLERANCE: f64 = 12.0;
/// The least part of the page worth looking at: less is a margin.
pub const MIN_GAP: f64 = 24.0;
/// Tells the model why a scroll it planned was not made.
pub const BLUE_SCROLL_NOTE: &str = "You planned a scroll to a part of the page you settled (blue on the page's map): you will not need to come back to it, so the harness did not go there.";

/// A stretch of the page, from and to in screenshot pixels from its top.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Span {
    pub from: f64,
    pub to: f64,
}

/// The spans in order, with those that overlap or touch made one.
pub fn merge_spans(spans: &[Span]) -> Vec<Span> {
    let mut sorted = spans.to_vec();
    sorted.sort_by(|a, b| a.from.total_cmp(&b.from));
    let mut out: Vec<Span> = Vec::new();
    for span in sorted {
        if let Some(last) = out.last_mut()
            && span.from <= last.to + 1.0
        {
            last.to = last.to.max(span.to);
            continue;
        }
        out.push(span);
    }
    out
}

/// What the browser is told when the settled parts changed: it paints them on the map the person
/// sees and does not photograph them again in the next survey. The fence is how far down the
/// page the plan being carried out leaves things as they are: it begins at the first point the
/// plan acts on.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettledMap {
    pub page_height: f64,
    pub fence: f64,
    pub spans: Vec<Span>,
}

/// What is settled on the page the run is on: the page, its height when the parts were settled,
/// the stretches, and where the plan being carried out first acts.
#[derive(Clone, Debug, Default)]
pub struct Settled {
    pub url: String,
    pub page_height: f64,
    pub spans: Vec<Span>,
    pub fence: f64,
    /// Set when the spans changed since they were last sent to the browser.
    changed: bool,
}

/// What a run has looked at on the page it is on.
#[derive(Clone, Debug, Default)]
pub struct Coverage {
    url: String,
    height: f64,
    spans: Vec<Span>,
}

impl Coverage {
    /// Records the part of the page a look showed. A new address, or a page that changed height,
    /// starts again: the earlier parts may not be where they were.
    pub fn see(&mut self, url: &str, vp: &Viewport) {
        if vp.page_height <= 0.0 {
            return;
        }
        let url = without_fragment(url);
        if url != self.url || (vp.page_height - self.height).abs() > HEIGHT_TOLERANCE {
            self.spans.clear();
        }
        self.url = url.to_string();
        self.height = vp.page_height;
        let from = vp.scroll_y.max(0.0);
        let to = (vp.scroll_y + vp.height as f64).min(vp.page_height);
        if to > from {
            self.spans.push(Span { from, to });
            self.spans = merge_spans(&self.spans);
        }
    }

    /// The parts of the page no look has shown, from the top.
    pub fn gaps(&self) -> Vec<Span> {
        let mut out = Vec::new();
        let mut cursor = 0.0;
        for seen in &self.spans {
            if seen.from - cursor > MIN_GAP {
                out.push(Span { from: cursor, to: seen.from });
            }
            cursor = cursor.max(seen.to);
        }
        if self.height - cursor > MIN_GAP {
            out.push(Span { from: cursor, to: self.height });
        }
        out
    }

    /// What the model is told about the page's reach, or nothing when the page fits the screen.
    pub fn line(&self, vp: &Viewport) -> String {
        if self.height <= vp.height as f64 + 8.0 {
            return String::new();
        }
        let gaps = self.gaps();
        if gaps.is_empty() {
            return format!("The page is {:.0} px tall (pixels from its top). You have looked at all of it.", self.height);
        }
        format!(
            "The page is {:.0} px tall (pixels from its top). You have looked at: {}. You have not looked at: {}. A required question may be in a part you have not seen.",
            self.height,
            format_spans(&self.spans),
            format_spans(&gaps)
        )
    }
}

fn format_spans(spans: &[Span]) -> String {
    spans.iter().map(|span| format!("{:.0} to {:.0}", span.from, span.to)).collect::<Vec<_>>().join(", ")
}

impl Session {
    /// Drops what was settled when the look is of another page. At another height, with nothing
    /// to say what moved: a page that shrank had its bottom cut, and one that grew had its pixels
    /// added at the bottom, so what was settled stays where it was.
    pub(crate) fn forget_settled_if_stale(&mut self, obs: &Observation) {
        if self.settled.spans.is_empty() {
            return;
        }
        if self.settled.url != without_fragment(&obs.url) {
            self.settled = Settled { changed: true, ..Settled::default() };
            return;
        }
        let height = obs.viewport.page_height;
        if (height - self.settled.page_height).abs() <= HEIGHT_TOLERANCE {
            return;
        }
        if height + HEIGHT_TOLERANCE < self.settled.page_height {
            self.settled.spans = crop_settled(&self.settled.spans, height);
        }
        self.settled.page_height = height;
        self.settled.changed = true;
    }

    /// Records that the model has looked at every screen of a survey, and at every settled part:
    /// the page's reach is told to the model as what it has not looked at, and a survey it was
    /// shown, or a part it settled, is looked at.
    pub(crate) fn see_survey(&mut self, obs: &Observation) {
        for screen in &obs.survey {
            let mut view = obs.viewport;
            view.scroll_y = screen.scroll_y;
            self.cover.see(&obs.url, &view);
        }
        for span in &self.settled.spans {
            let mut view = obs.viewport;
            view.scroll_y = span.from;
            view.height = (span.to - span.from).max(0.0) as u32;
            self.cover.see(&obs.url, &view);
        }
    }

    /// Records the screens of the survey the model said it will not come back to, except those
    /// the plan acts on, and those with a field the to-do list has empty: the run comes back to
    /// them. A recorded run settled the only screen that showed a required box whole, and then
    /// aimed at it four times where it was cut off at a screen's edge. Says how many it settled.
    pub(crate) fn mark_settled(&mut self, obs: &Observation, screens: &[u32], planned: &[Action]) -> usize {
        if obs.survey.is_empty() || screens.is_empty() {
            return 0;
        }
        let touched = touched_screens(planned, obs);
        let height = obs.viewport.height as f64;
        let mut added = Vec::new();
        for &n in screens {
            let Some(screen) = n.checked_sub(1).and_then(|i| obs.survey.get(i as usize)) else { continue };
            let (from, to) = (screen.scroll_y, screen.scroll_y + height);
            if touched.contains(&n) || self.empty_field_near(&obs.url, from, to) {
                continue;
            }
            added.push(Span { from, to });
        }
        if added.is_empty() {
            return 0;
        }
        self.settled.url = without_fragment(&obs.url).to_string();
        self.settled.page_height = obs.viewport.page_height;
        let mut spans = self.settled.spans.clone();
        spans.extend(&added);
        self.settled.spans = merge_spans(&spans);
        self.settled.changed = true;
        added.len()
    }

    /// What the browser is told when the settled parts changed, and forgets that they changed.
    /// An empty map tells it that nothing is settled any more.
    pub(crate) fn take_settled_map(&mut self) -> Option<SettledMap> {
        if !self.settled.changed {
            return None;
        }
        self.settled.changed = false;
        Some(SettledMap { page_height: self.settled.page_height, fence: self.settled.fence, spans: self.settled.spans.clone() })
    }

    /// Tells the model what a survey leaves out.
    pub(crate) fn settled_note(&self) -> String {
        if self.settled.spans.is_empty() {
            return String::new();
        }
        let parts: Vec<String> = self.settled.spans.iter().map(|span| format!("{:.0} to {:.0} px", span.from, span.to)).collect();
        format!(
            "You settled these parts of the page and they are not shown again (blue on the page's map): {}. Everything else is in the survey. List in \"settled\" the screens you will not need to come back to.",
            parts.join("; ")
        )
    }

    /// The plan without the scrolls that would end with the window wholly inside a part of the
    /// page the model settled: it never goes back into one. A scroll is judged from where the
    /// window is when it is made, which is where the plan's earlier scrolls and its pinned points
    /// put it. Says how many it dropped.
    pub(crate) fn without_blue_scrolls(&self, planned: Vec<Action>, obs: &Observation) -> (Vec<Action>, usize) {
        if self.settled.spans.is_empty() {
            return (planned, 0);
        }
        let height = obs.viewport.height as f64;
        let last = (obs.viewport.page_height - height).max(0.0);
        let mut at = obs.viewport.scroll_y;
        let mut kept = Vec::new();
        let mut dropped = 0;
        for action in planned {
            if let Some(to) = action.scroll_to {
                at = to;
            }
            if let Kind::Scroll { dy, .. } = action.kind {
                let target = (at + dy).clamp(0.0, last);
                if self.in_settled(target, height) {
                    dropped += 1;
                    continue;
                }
                at = target;
            }
            kept.push(action);
        }
        (kept, dropped)
    }

    /// Whether the window of the given height, with its top at `y`, lies wholly in a settled
    /// stretch.
    pub(crate) fn in_settled(&self, y: f64, height: f64) -> bool {
        self.settled.spans.iter().any(|span| span.from <= y + 1.0 && span.to >= y + height - 1.0)
    }

    /// Takes a stretch of the page out of what is settled: the run goes back there.
    pub(crate) fn unsettle(&mut self, from: f64, to: f64) {
        if self.settled.spans.is_empty() {
            return;
        }
        let mut kept = Vec::new();
        for span in &self.settled.spans {
            if span.to <= from || span.from >= to {
                kept.push(*span);
                continue;
            }
            if span.from < from {
                kept.push(Span { from: span.from, to: from });
            }
            if span.to > to {
                kept.push(Span { from: to, to: span.to });
            }
        }
        if kept != self.settled.spans {
            self.settled.spans = kept;
            self.settled.changed = true;
        }
    }

    /// Records where the plan about to be carried out first acts on the page, and tells the
    /// browser when that changed what it knows.
    pub(crate) fn set_fence(&mut self, planned: &[Action], obs: &Observation) {
        let fence = fence_of(planned, obs);
        if fence != self.settled.fence {
            self.settled.fence = fence;
            self.settled.changed = true;
        }
    }
}

/// The screens of a survey the plan acts on: an action is on the screen it is pinned to. A screen
/// with an action on it is not settled by the same answer: it is looked at again first.
fn touched_screens(planned: &[Action], obs: &Observation) -> BTreeSet<u32> {
    let mut touched = BTreeSet::new();
    for action in planned {
        let Some(to) = action.scroll_to else { continue };
        for (i, screen) in obs.survey.iter().enumerate() {
            if (screen.scroll_y - to).abs() <= 1.0 {
                touched.insert(i as u32 + 1);
            }
        }
    }
    touched
}

/// How far down the page a plan leaves things as they are: the page position of the first point
/// it acts on. A plan that acts on no point leaves the whole page as it is.
fn fence_of(planned: &[Action], obs: &Observation) -> f64 {
    let mut fence = obs.viewport.page_height;
    for action in planned {
        let Some(point) = action.point() else { continue };
        fence = fence.min(action.scroll_to.unwrap_or(obs.viewport.scroll_y) + point.y);
    }
    fence
}

/// Drops the part of each stretch past `height`, and stretches that start there.
fn crop_settled(spans: &[Span], height: f64) -> Vec<Span> {
    spans
        .iter()
        .filter(|span| span.from < height - 1.0)
        .map(|span| Span { from: span.from, to: span.to.min(height) })
        .filter(|span| span.to - span.from > 1.0)
        .collect()
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
    fn settled_screens_are_mapped_told_back_and_not_scrolled_into() {
        // The model settles screens 1 and 3, but acts on screen 3, so only screen 1 settles; its
        // scroll back up to the top would end inside it.
        let reply = r#"{"status":"working","message":"","settled":[1,3],"fields":[],
            "actions":[{"kind":"click","screen":3,"x":10,"y":10,"label":"Send"},{"kind":"scroll","dy":-100}]}"#;
        let (model, seen) = Replying::new(reply);
        let agent = Agent::new(Config::default(), model);
        let id = agent.start(Task::new("fill the form"), Profile::default());
        let survey = || {
            let mut obs = look(false, &[]);
            obs.viewport.page_height = 160.0;
            obs.survey = [0.0, 50.0, 100.0].iter().map(|y| SurveyScreen { screenshot: obs.screenshot.clone(), scroll_y: *y }).collect();
            obs
        };
        let first = agent.step(&id, survey()).unwrap();
        assert_eq!(first.actions.len(), 2);
        assert_eq!(first.settled, Some(SettledMap { page_height: 160.0, fence: 110.0, spans: vec![Span { from: 0.0, to: 60.0 }] }));
        let second = agent.step(&id, survey()).unwrap();
        assert_eq!(second.actions.len(), 1);
        assert_eq!(second.dropped, vec!["1 scroll to a settled part of the page not made"]);
        // Settled again by the model: the map is sent again, the same.
        assert_eq!(second.settled, first.settled);
        let seen = seen.lock().unwrap();
        assert!(seen[1].contains("The page is 160 px tall (pixels from its top). You have looked at all of it."), "{}", seen[1]);
        assert!(seen[1].contains("You settled these parts of the page and they are not shown again (blue on the page's map): 0 to 60 px."), "{}", seen[1]);
        assert_eq!(merge_spans(&[Span { from: 10.0, to: 20.0 }, Span { from: 0.0, to: 11.0 }, Span { from: 30.0, to: 40.0 }]), vec![Span { from: 0.0, to: 20.0 }, Span { from: 30.0, to: 40.0 }]);
    }
}
