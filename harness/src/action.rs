//! What the model may ask the browser to do, and how actions group into batches that run
//! without the model looking in between.
//!
//! An action serializes flat, as `{"id": ..., "kind": "click", "x": ..., "y": ...}`, the shape
//! Acorn's extension protocol uses. Fields the browser never needs (what the model called the
//! control, what the click commits, what the screen should show after) stay on the harness.

use serde::{Deserialize, Serialize};

/// One thing for the browser to do, at one point of the page.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Action {
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
    Click { x: f64, y: f64 },
    DoubleClick { x: f64, y: f64 },
    TripleClick { x: f64, y: f64 },
    RightClick { x: f64, y: f64 },
    Hover { x: f64, y: f64 },
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
    /// Not sent to the browser: the model asks for the next look to be a survey of the whole page.
    Survey,
}

impl Kind {
    /// The point the action acts at, when it has one. A scroll's point is where the wheel
    /// turns, not a target, so it is not one.
    pub fn point(&self) -> Option<Point> {
        match *self {
            Kind::Click { x, y }
            | Kind::DoubleClick { x, y }
            | Kind::TripleClick { x, y }
            | Kind::RightClick { x, y }
            | Kind::Hover { x, y }
            | Kind::Upload { x, y, .. } => Some(Point { x, y }),
            _ => None,
        }
    }

    /// Whether the browser carries this action out. The rest are requests to the harness.
    pub fn is_for_browser(&self) -> bool {
        !matches!(self, Kind::Survey)
    }
}

/// What a click does beyond the click, in the model's judgment of the screen.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Commit {
    /// An ordinary click.
    #[default]
    None,
    /// Goes on to another page or step of the same task.
    Next,
    /// Commits the task to the outside: sends, submits, pays, posts. The gate decides whether
    /// such a click may go out.
    Send,
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
        let mut a = Action::new(id, Kind::Click { x: 1.0, y: 2.0 });
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
