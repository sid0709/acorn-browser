//! What the model may ask the browser to do, and how actions group into batches that run
//! without the model looking in between.
//!
//! An action serializes flat, as `{"id": ..., "kind": "click", "x": ..., "y": ...}`, the shape
//! Acorn's extension protocol uses. Fields the browser never needs (what the model called the
//! control, what the click commits, what the screen should show after) stay on the harness.

use serde::{Deserialize, Serialize};

use crate::task::Irreversible;

/// One thing for the browser to do, at one point of the page.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Action {
    /// Given by the harness as the plan is taken, as `s<step>a<n>`; the model does not name it.
    #[serde(default)]
    pub id: String,
    #[serde(flatten)]
    pub kind: Kind,
    /// The scroll position (screenshot pixels) the page must be at before the action, because
    /// its point was measured on that screen of a survey. `None` means the current position.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scroll_to: Option<f64>,
    /// The page's height when the point was measured, so the browser can tell the page changed
    /// shape since and refuse rather than act at a point that moved. 0 when unknown.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub page_height: f64,
    /// The survey screen (from 1) the action belongs to, so the browser can take a photo when
    /// the last action of a zone is done. 0 when the plan was made from one screen.
    #[serde(default, skip_serializing_if = "is_zero_u32")]
    pub zone: u32,
    /// What the model called the control at the point, in the page's words. Read from the
    /// model's reply; never sent to the browser. The point is checked against it before the
    /// action goes out.
    #[serde(default, skip_serializing)]
    pub label: String,
    /// What the model said this click does beyond the click. Never sent to the browser.
    #[serde(default, skip_serializing)]
    pub commit: Commit,
    /// What the screen should show once this action has run, in the model's words. A batch
    /// ends here and the screen is checked against it. Empty means no check.
    #[serde(default, skip_serializing)]
    pub check: String,
}

impl Action {
    /// An action with no survey placement and nothing said about it.
    pub fn new(id: impl Into<String>, kind: Kind) -> Self {
        Action {
            id: id.into(),
            kind,
            scroll_to: None,
            page_height: 0.0,
            zone: 0,
            label: String::new(),
            commit: Commit::None,
            check: String::new(),
        }
    }

    /// The point the action acts at, when it has one.
    pub fn point(&self) -> Option<Point> {
        self.kind.point()
    }
}

/// A point of the page, in screenshot pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// The kinds of action, with what each needs.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Kind {
    /// A click at the point, with the `modifiers` held meanwhile (`Shift`, `Meta+Shift`; empty
    /// for none), as every pointing kind below.
    Click {
        x: f64,
        y: f64,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        modifiers: String,
    },
    DoubleClick {
        x: f64,
        y: f64,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        modifiers: String,
    },
    TripleClick {
        x: f64,
        y: f64,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        modifiers: String,
    },
    RightClick {
        x: f64,
        y: f64,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        modifiers: String,
    },
    Hover {
        x: f64,
        y: f64,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        modifiers: String,
    },
    /// The mouse button goes down at the first point of `path`, moves through the rest, and
    /// comes up at the last: moving a slider or a card, sweeping over text, drawing a stroke.
    Drag {
        path: Vec<Point>,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        modifiers: String,
    },
    /// Typed into the focused control.
    Type {
        text: String,
        /// A password or a code: the value never appears in a log.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        secret: bool,
    },
    /// One key or chord (`Enter`, `Control+a`, `ArrowDown`), or several separated by spaces.
    Key { keys: String },
    /// Scroll by `dx`, `dy` screenshot pixels (positive goes right and down), with the wheel at
    /// the point when one is given.
    Scroll {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        x: Option<f64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        y: Option<f64>,
        #[serde(default)]
        dx: f64,
        #[serde(default)]
        dy: f64,
    },
    /// Click the control at the point and answer the file picker with a file of the task's.
    Upload {
        x: f64,
        y: f64,
        /// The resource to upload, by its id in the task. Empty lets the harness choose.
        #[serde(default, skip_serializing_if = "String::is_empty")]
        resource: String,
        /// Set by the harness once the resource is chosen; what the browser hands the page.
        #[serde(default, skip_serializing_if = "String::is_empty")]
        file_name: String,
    },
    Wait { ms: u64 },
    /// Go to an address: another site, or another page of this one, when no link leads there.
    Navigate { url: String },
    /// Go back to the page before this one.
    Back,
    /// Not sent to the browser: the model asks for the next look to be a survey of the whole page.
    Survey,
    /// Not sent to the browser: the model asks for the rest of its kept plan to run as planned.
    Resume,
}

impl Kind {
    /// The point the action acts at, when it has one. A scroll's point is where the wheel
    /// turns, not a target, so it is not one.
    pub fn point(&self) -> Option<Point> {
        match self {
            Kind::Click { x, y, .. }
            | Kind::DoubleClick { x, y, .. }
            | Kind::TripleClick { x, y, .. }
            | Kind::RightClick { x, y, .. }
            | Kind::Hover { x, y, .. }
            | Kind::Upload { x, y, .. } => Some(Point { x: *x, y: *y }),
            // A drag's point is where it takes hold.
            Kind::Drag { path, .. } => path.first().copied(),
            _ => None,
        }
    }

    /// Whether the browser carries this action out. The rest are requests to the harness.
    pub fn is_for_browser(&self) -> bool {
        !matches!(self, Kind::Survey | Kind::Resume)
    }
}

/// What a click does beyond the click, in the model's judgment of the screen. The kinds that
/// commit something beyond the page are the gate's to let out, as the person allows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Commit {
    /// An ordinary click.
    #[default]
    None,
    /// Goes on to another page or step of the same task.
    Next,
    /// Sends or submits to someone: an application, a message, an order.
    Send,
    Pay,
    /// Publishes where others see it.
    Post,
    Delete,
    CreateAccount,
}

impl Commit {
    /// The kind of action that cannot be taken back the click is, when it is one.
    pub fn irreversible(self) -> Option<Irreversible> {
        match self {
            Commit::Send => Some(Irreversible::Send),
            Commit::Pay => Some(Irreversible::Pay),
            Commit::Post => Some(Irreversible::Post),
            Commit::Delete => Some(Irreversible::Delete),
            Commit::CreateAccount => Some(Irreversible::CreateAccount),
            Commit::None | Commit::Next => None,
        }
    }
}

/// Gives the actions without a point (typing, keys, scrolls, waits) the zone of the action before
/// them, and the ones before the first point the first zone, so a zone's photo is taken once its
/// typing is done too. Changes nothing when no action has a zone.
pub fn inherit_zones(actions: &mut [Action]) {
    let Some(first) = actions.iter().map(|a| a.zone).find(|zone| *zone > 0) else { return };
    let mut current = first;
    for action in actions {
        if action.zone > 0 {
            current = action.zone;
        } else {
            action.zone = current;
        }
    }
}

/// A run of actions the browser carries out without the model looking in between, and what the
/// screen should show when it is done.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Batch {
    pub actions: Vec<Action>,
    /// The model's own words for the expected screen; empty means the model asked to look first.
    pub expect: String,
}

/// Cuts a plan into batches. A batch ends at an action the model put a check on, after `limit`
/// actions when it did not (0 for no limit), and always before and after a scroll so the
/// coordinates of what follows stay valid. With `at_uploads`, a batch also ends after an upload,
/// so the screen is verified before the page moves.
pub fn split_plan(actions: Vec<Action>, limit: usize, at_uploads: bool) -> Vec<Batch> {
    let mut out = Vec::new();
    let mut current: Vec<Action> = Vec::new();
    let flush = |current: &mut Vec<Action>, out: &mut Vec<Batch>, expect: &str| {
        if current.is_empty() {
            return;
        }
        out.push(Batch {
            actions: std::mem::take(current),
            expect: expect.to_string(),
        });
    };
    for action in actions {
        let is_scroll = matches!(action.kind, Kind::Scroll { .. });
        if is_scroll && let Some(last) = current.last() {
            let expect = last.check.clone();
            flush(&mut current, &mut out, &expect);
        }
        let check = action.check.clone();
        let is_upload = matches!(action.kind, Kind::Upload { .. });
        current.push(action);
        if is_upload && at_uploads {
            flush(&mut current, &mut out, &check);
            continue;
        }
        if !check.is_empty() || (limit > 0 && current.len() == limit) {
            flush(&mut current, &mut out, &check);
            continue;
        }
        if is_scroll {
            flush(&mut current, &mut out, &check);
        }
    }
    flush(&mut current, &mut out, "");
    out
}

/// How many fields a plan must fill on one screen before they run as one batch with one check,
/// instead of a check after each.
pub const MIN_FILLS_FOR_ONE_CHECK: usize = 2;

/// How the checks of several fields filled in one batch begin once they are combined into one
/// expected screen. A check that fails with this prefix cannot say which field was wrong.
pub const COMBINED_CHECK_PREFIX: &str = "The screen shows all of the following after the last actions: ";

/// Cuts a plan into batches for a run whose screen is checked. When the actions before the first
/// scroll or upload fill at least [`MIN_FILLS_FOR_ONE_CHECK`] fields, they run as one batch with
/// one check, every check the model put on them combined; the rest of the plan is cut as
/// [`split_plan`] cuts it. Scrolling belongs on the next look after a check, not in a batch that
/// fills several fields.
pub fn split_plan_for_checks(actions: Vec<Action>, limit: usize, at_uploads: bool) -> Vec<Batch> {
    let cut = actions.iter().position(|a| matches!(a.kind, Kind::Scroll { .. } | Kind::Upload { .. })).unwrap_or(actions.len());
    let fills = actions[..cut].iter().filter(|a| matches!(a.kind, Kind::Type { .. })).count();
    if fills >= MIN_FILLS_FOR_ONE_CHECK {
        let expect = combined_check(&actions[..cut]);
        if !expect.is_empty() {
            let mut rest = actions;
            let first: Vec<Action> = rest.drain(..cut).collect();
            let mut out = vec![Batch { actions: first, expect }];
            if !rest.is_empty() {
                out.extend(split_plan(rest, limit, at_uploads));
            }
            return out;
        }
    }
    split_plan(actions, limit, at_uploads)
}

/// What the checker reads after a batch that fills several fields: every check the model set on
/// them, in one sentence.
fn combined_check(actions: &[Action]) -> String {
    let parts: Vec<&str> = actions.iter().map(|a| a.check.trim()).filter(|c| !c.is_empty()).collect();
    match parts.len() {
        0 => String::new(),
        1 => parts[0].to_string(),
        _ => format!("{COMBINED_CHECK_PREFIX}{}", parts.join("; ")),
    }
}

/// The least a label may have, once its words are read, to agree with another: a label of a
/// letter or two would begin too many others.
pub const MIN_LABEL_AGREE_CHARS: usize = 3;
/// A beginning long enough to agree in the middle of a word: both the model's label and the
/// page's are cut short at a fixed length, which falls where it falls.
pub const LONG_LABEL_AGREE_CHARS: usize = 24;

/// A label as words only: lower case, with every run of anything but a letter or a digit made
/// one space, so case, spacing and punctuation (a required mark, a colon) do not count.
pub fn label_words(label: &str) -> String {
    let mut out = String::with_capacity(label.len());
    let mut space = false;
    for c in label.to_lowercase().chars() {
        if c.is_alphanumeric() {
            if space && !out.is_empty() {
                out.push(' ');
            }
            space = false;
            out.push(c);
        } else {
            space = true;
        }
    }
    out
}

/// Whether two labels name the same control: the same words, or one begins with the other's
/// words, since the model writes a long question in a few words and a page's own label is cut
/// short. Neither may be empty or too short.
pub fn labels_agree(a: &str, b: &str) -> bool {
    let (a, b) = (label_words(a), label_words(b));
    if a.len() < MIN_LABEL_AGREE_CHARS || b.len() < MIN_LABEL_AGREE_CHARS {
        return false;
    }
    a == b || begins_with_words(&a, &b) || begins_with_words(&b, &a)
}

/// Whether the text starts with the whole words of the prefix, or with a long enough prefix
/// wherever it was cut.
fn begins_with_words(text: &str, prefix: &str) -> bool {
    text.starts_with(prefix) && (text.len() == prefix.len() || text.as_bytes()[prefix.len()] == b' ' || prefix.len() >= LONG_LABEL_AGREE_CHARS)
}

fn is_zero(v: &f64) -> bool {
    *v == 0.0
}

fn is_zero_u32(v: &u32) -> bool {
    *v == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn click(id: &str, check: &str) -> Action {
        let mut a = Action::new(id, Kind::Click { x: 1.0, y: 2.0, modifiers: String::new() });
        a.check = check.to_string();
        a
    }

    #[test]
    fn a_plan_splits_at_checks_scrolls_and_the_limit() {
        let scroll = Action::new("s", Kind::Scroll { x: None, y: None, dx: 0.0, dy: 500.0 });
        let plan = vec![click("a", ""), click("b", "the box is ticked"), click("c", ""), scroll, click("d", ""), click("e", ""), click("f", "")];
        let batches = split_plan(plan, 2, false);
        let ids: Vec<Vec<&str>> = batches.iter().map(|b| b.actions.iter().map(|a| a.id.as_str()).collect()).collect();
        assert_eq!(ids, vec![vec!["a", "b"], vec!["c"], vec!["s"], vec!["d", "e"], vec!["f"]]);
        assert_eq!(batches[0].expect, "the box is ticked");
        assert_eq!(batches[1].expect, "");
    }

    #[test]
    fn several_fields_filled_on_one_screen_are_checked_once() {
        let typed = |id: &str, check: &str| {
            let mut a = Action::new(id, Kind::Type { text: "x".into(), secret: false });
            a.check = check.to_string();
            a
        };
        let scroll = Action::new("s", Kind::Scroll { x: None, y: None, dx: 0.0, dy: 500.0 });
        let plan = vec![click("c1", ""), typed("t1", "Name shows x"), click("c2", ""), typed("t2", "Email shows x"), scroll, click("c3", "the box is ticked")];
        let batches = split_plan_for_checks(plan, 2, true);
        let ids: Vec<Vec<&str>> = batches.iter().map(|b| b.actions.iter().map(|a| a.id.as_str()).collect()).collect();
        assert_eq!(ids, vec![vec!["c1", "t1", "c2", "t2"], vec!["s"], vec!["c3"]]);
        assert_eq!(batches[0].expect, format!("{COMBINED_CHECK_PREFIX}Name shows x; Email shows x"));
        // One field only: cut as usual, at the limit.
        assert_eq!(split_plan_for_checks(vec![click("c1", ""), typed("t1", ""), click("c2", "")], 2, true).len(), 2);
    }

    #[test]
    fn labels_agree_on_their_words() {
        assert!(labels_agree("First name *", "first name"));
        assert!(labels_agree("Email", "Email address"));
        assert!(!labels_agree("Email", "Emailing"));
        assert!(!labels_agree("A", "A"));
    }

    #[test]
    fn an_action_serializes_flat_without_harness_fields() {
        let mut a = Action::new("1", Kind::Type { text: "hi".into(), secret: false });
        a.label = "First name".into();
        a.check = "shows hi".into();
        let json = serde_json::to_string(&a).unwrap();
        assert_eq!(json, r#"{"id":"1","kind":"type","text":"hi"}"#);
        let back: Action = serde_json::from_str(r#"{"id":"2","kind":"click","x":3,"y":4,"label":"Send","commit":"send"}"#).unwrap();
        assert_eq!(back.point(), Some(Point { x: 3.0, y: 4.0 }));
        assert_eq!(back.commit, Commit::Send);
        assert_eq!(back.label, "Send");
    }
}
