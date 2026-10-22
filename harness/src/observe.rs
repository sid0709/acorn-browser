//! What the browser reports at each step: the screenshot, the viewport, the page, the results of
//! the last actions, and what has focus.
//!
//! The harness is image based. The model measures every point in the screenshot it is shown, so
//! the screenshot and the viewport it describes must agree; `run` checks that before a step.
//! Field names serialize in camelCase so a browser side written against Acorn's extension
//! protocol can talk to this harness unchanged.

use serde::{Deserialize, Serialize};

/// One look at the page, sent by the browser before each step.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Observation {
    /// A data URL (`image/jpeg` or `image/png`) of the visible page.
    pub screenshot: String,
    pub url: String,
    pub title: String,
    pub viewport: Viewport,
    /// The focused control, when the page has one. The one thing read from the page rather than
    /// the picture: it tells whether a click reached its control.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus: Option<Focus>,
    /// Things the screenshot cannot show: a dialog the browser closed, a file that downloaded,
    /// a tab the page opened.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<String>,
    /// The whole page as screenshots from top to bottom, each at its own scroll position. Sent
    /// on the first look of a page and when the model asks; the model plans the whole page from
    /// it. Empty on an ordinary look.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub survey: Vec<SurveyScreen>,
    /// What became of the actions sent at the step before.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub results: Vec<ActionResult>,
}

/// The window onto the page, in screenshot pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Viewport {
    pub width: u32,
    pub height: u32,
    /// The page's scroll offset.
    pub scroll_x: f64,
    pub scroll_y: f64,
    /// The page's whole size. With the scroll offset, it says how much page lies off screen.
    pub page_width: f64,
    pub page_height: f64,
}

impl Viewport {
    /// Whether the viewport can hold a screenshot at all.
    pub fn has_size(&self) -> bool {
        self.width > 0 && self.height > 0
    }
}

/// The control that has focus, as the page describes it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Focus {
    /// The element's tag (`input`, `select`, `textarea`, `button`, ...).
    pub tag: String,
    /// The input's type (`text`, `checkbox`, `file`, ...), when it has one.
    #[serde(default, rename = "type", skip_serializing_if = "String::is_empty")]
    pub kind: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub label: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub value: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked: Option<bool>,
    /// The options of a native select, as text.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub multiple: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub required: bool,
    /// The page's own validation message for the control, when it shows one.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub invalid: String,
}

/// One screen of a survey: the page at one scroll position.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SurveyScreen {
    pub screenshot: String,
    pub scroll_y: f64,
}

/// What became of one action.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionResult {
    /// The id of the action, as the plan named it.
    pub id: String,
    pub ok: bool,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub error: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub detail: String,
    /// Something the action set off that a screenshot cannot show.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opened: Option<Opened>,
    /// The action reached no control (typing or a key with nothing focused). The rest of the
    /// batch went on, so the plan is not given up for it; the field it was for stays open.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub unreached: bool,
}

/// What a click can open outside the page's picture.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Opened {
    /// The browser's file picker. The browser side intercepts it; the harness answers with the
    /// file to upload.
    FilePicker,
}
