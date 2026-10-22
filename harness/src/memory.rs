//! The model's memory of the run: recent turns in full, older turns folded into one line each,
//! and compaction when the token budget is reached.
//!
//! The prompt only ever grows at its end. A provider bills a repeated prompt prefix at a
//! fraction of the price, and the first change anywhere in the prompt makes everything after it
//! new. So old screenshots are dropped from the turns that replay them (they sat in a past
//! step's current message, never in a replayed prefix), and compaction folds the oldest turns in
//! one go, far below budget, so the prompt grows by appending for many steps before it is
//! compacted again.

use crate::action::{Action, Kind};
use crate::ports::{Message, Role};

/// What a screenshot is taken to cost against the token budget.
pub const APPROX_IMAGE_TOKENS: usize = 1200;
/// The most characters one folded line keeps.
pub const MAX_SUMMARY_CHARS: usize = 240;
/// The most folded lines a run keeps.
pub const MAX_FOLDED_LINES: usize = 80;

/// One step of the run as the model lived it.
#[derive(Clone, Debug)]
pub struct Turn {
    pub number: u32,
    /// What the model was told beside the screenshots, exactly as it was sent.
    pub text: String,
    /// The screenshots shown with it; dropped once the turn is older than the kept window.
    pub images: Vec<String>,
    /// The model's reply, as JSON, replayed as its own earlier turn.
    pub answer: String,
    /// The one line that stands for the turn once it is folded away.
    pub summary: String,
}

/// The run's history: recent turns in full, older ones folded to a line each.
#[derive(Clone, Debug, Default)]
pub struct Memory {
    turns: Vec<Turn>,
    folded: Vec<String>,
}

impl Memory {
    /// Records a step: what the model was told and showed, what it answered, and the one line
    /// that will stand for the turn once it is folded.
    pub fn record(&mut self, turn: Turn) {
        self.turns.push(turn);
    }

    /// The model's view of the run before the current step: the folded summary, then every kept
    /// turn as it was sent and answered. Only the newest `keep_images` turns still carry their
    /// screenshots; the model reads the current screen from the current step's own screenshot,
    /// and an old one only makes every request bigger.
    pub fn history(&self, keep_images: usize) -> Vec<Message> {
        let mut out = Vec::new();
        if !self.folded.is_empty() {
            out.push(Message {
                role: Role::User,
                text: format!("Earlier in this run (oldest first; your notes below are the full picture):\n- {}", self.folded.join("\n- ")),
                ..Default::default()
            });
        }
        let keep_from = self.turns.len().saturating_sub(keep_images);
        for (i, turn) in self.turns.iter().enumerate() {
            let mut message = Message { role: Role::User, text: turn.text.clone(), ..Default::default() };
            if !turn.images.is_empty() && i >= keep_from {
                message.images = turn.images.clone();
            } else if !turn.images.is_empty() {
                message.text.push_str("\n(Screenshot no longer kept.)");
            }
            out.push(message);
            out.push(Message { role: Role::Assistant, text: turn.answer.clone(), ..Default::default() });
        }
        out
    }

    /// Drops the screenshots of every turn but the newest `keep_images`, which `history` would
    /// not send again, so a long run does not hold them in memory.
    pub fn release_images(&mut self, keep_images: usize) {
        let keep_from = self.turns.len().saturating_sub(keep_images);
        for turn in &mut self.turns[..keep_from] {
            turn.images.clear();
        }
    }

    /// How many turns are kept in full.
    pub fn len(&self) -> usize {
        self.turns.len()
    }

    pub fn is_empty(&self) -> bool {
        self.turns.is_empty()
    }
}

/// The one line that stands for a step once it is folded: its number, the model's message, and
/// what its actions did.
pub fn summary_line(number: u32, message: &str, actions: &[Action]) -> String {
    let mut line = format!("step {number}: {}", message.trim());
    if !actions.is_empty() {
        let parts: Vec<String> = actions.iter().map(describe).collect();
        line.push_str(&format!(" [{}]", parts.join("; ")));
    }
    line
}

/// One short phrase saying what an action did, for the history.
fn describe(action: &Action) -> String {
    match &action.kind {
        Kind::Type { text, secret: true } => format!("type [{} secret characters]", text.chars().count()),
        Kind::Type { text, secret: false } => format!("type {:?}", clip(text, 60)),
        Kind::Key { keys } => format!("key {keys}"),
        Kind::Scroll { dx, dy, .. } => format!("scroll {dx:.0},{dy:.0}"),
        Kind::Wait { ms } => format!("wait {ms}ms"),
        Kind::Survey => "survey".to_string(),
        Kind::Upload { x, y, file_name, .. } if !file_name.is_empty() => format!("upload {file_name} at {x:.0},{y:.0}"),
        other => {
            let name = match other {
                Kind::Click { .. } => "click",
                Kind::DoubleClick { .. } => "double_click",
                Kind::TripleClick { .. } => "triple_click",
                Kind::RightClick { .. } => "right_click",
                Kind::Hover { .. } => "hover",
                Kind::Upload { .. } => "upload",
                _ => "action",
            };
            match other.point() {
                Some(p) => format!("{name} at {:.0},{:.0}", p.x, p.y),
                None => name.to_string(),
            }
        }
    }
}

fn clip(text: &str, max: usize) -> String {
    match text.char_indices().nth(max) {
        Some((end, _)) => text[..end].to_string(),
        None => text.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn turn(n: u32, img: bool) -> Turn {
        Turn {
            number: n,
            text: format!("step {n} text"),
            images: if img { vec![format!("img{n}")] } else { vec![] },
            answer: format!("{{\"n\":{n}}}"),
            summary: format!("step {n}: did a thing"),
        }
    }

    #[test]
    fn history_keeps_images_only_on_the_newest_turns() {
        let mut memory = Memory::default();
        memory.record(turn(1, true));
        memory.record(turn(2, true));
        memory.record(turn(3, true));
        let messages = memory.history(1);
        // Two messages (user, assistant) per turn, no folded block.
        assert_eq!(messages.len(), 6);
        assert!(messages[0].images.is_empty());
        assert!(messages[0].text.contains("Screenshot no longer kept."));
        assert_eq!(messages[4].images, vec!["img3".to_string()]);

        memory.release_images(1);
        assert!(memory.history(1)[4].images == vec!["img3".to_string()]);
        // The older turns' images are gone from memory, so even asking for more finds none.
        let kept: usize = memory.history(5).iter().filter(|m| !m.images.is_empty()).count();
        assert_eq!(kept, 1);
    }

    #[test]
    fn a_summary_line_names_the_step_and_its_actions() {
        let actions = vec![
            Action::new("a", Kind::Click { x: 10.0, y: 20.0 }),
            Action::new("b", Kind::Type { text: "hello".into(), secret: false }),
            Action::new("c", Kind::Type { text: "pw".into(), secret: true }),
        ];
        let line = summary_line(4, "  Filling the form.  ", &actions);
        assert_eq!(line, "step 4: Filling the form. [click at 10,20; type \"hello\"; type [2 secret characters]]");
    }
}
