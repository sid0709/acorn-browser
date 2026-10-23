//! The page map: what the browser knows of the page, as a list of lines the model can read
//! without a picture. It is the material of DOM mode, the second way the harness sees a page.
//!
//! The browser builds the map from its own knowledge of the page (in Chromium, the
//! accessibility tree joined with the DOM snapshot) and sends it with the observation. The
//! harness neither knows nor cares how: a map is a flat, depth-first list of nodes, each with a
//! role, a name, its live state, and its box in page coordinates (CSS pixels from the top left
//! of the document, the frame's offset already added). Nodes are numbered from 1 in the order
//! they are listed; in DOM mode the model names a node by that number, never by a point.
//!
//! The map is written for the model in two parts: the part of the page in view, one line per
//! node with its box, and a minimap of the rest, one line per screen's worth of page, so a long
//! page costs a few lines until the model scrolls to it. The whole stays under a budget.
//!
//! In stage 1 the map is only built and written to the trace; the model still sees screenshots.

use serde::{Deserialize, Serialize};

use crate::observe::Viewport;

/// The most bytes a map's text takes by default.
pub const BUDGET: usize = 24 * 1024;
/// The most minimap lines kept when the text is over budget.
const MIN_MINIMAP_LINES: usize = 4;
/// The most names one minimap line quotes.
const MINIMAP_NAMES: usize = 4;
const MINIMAP_HEADINGS: usize = 2;
const MINIMAP_NAME_CHARS: usize = 40;
const MINIMAP_HEADING_CHARS: usize = 60;
/// Deeper nesting than this is drawn at this depth: the indentation says enough.
const MAX_INDENT: u32 = 8;
/// A run of blocks of the same shape (the cards of a list of results) is folded once it has
/// this many: the first `FULL_BLOCKS` keep their lines, the rest get one line each.
const FOLD_AFTER: usize = 4;
const FULL_BLOCKS: usize = 2;
/// The longest shape of block looked for in a run of nodes with no list round them.
const MAX_PERIOD: usize = 16;
/// The most text lines a folded block keeps (a price, a rating).
const FOLDED_TEXTS: usize = 2;

/// The roles a person acts on.
const CONTROL_ROLES: &[&str] = &[
    "link", "button", "textbox", "searchbox", "combobox", "checkbox", "radio", "menuitem", "menuitemcheckbox", "menuitemradio", "tab", "option", "switch", "slider", "spinbutton", "listbox", "treeitem", "menubutton",
    "disclosure", "clickable", "frame",
];

/// The page as the browser reports it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageMap {
    /// Depth first, numbered from 1 in this order.
    #[serde(default)]
    pub nodes: Vec<PageNode>,
}

/// One line of the map.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageNode {
    pub id: u32,
    /// `text` for plain text; otherwise the control's or landmark's role as the browser names
    /// it (`button`, `link`, `textbox`, `heading`, `radiogroup`, `clickable` for a part of the
    /// page that is pressed but has no role, `frame` for an embedded page).
    pub role: String,
    /// The name the browser computed: its label, its `alt`, its `aria-label`, or its text.
    #[serde(default)]
    pub name: String,
    pub depth: u32,
    /// The box in page coordinates (CSS pixels from the document's top left).
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    /// Which embedded page the node is in: 0 for the page itself.
    #[serde(default)]
    pub frame: u32,
    /// The live state: `checked`, `selected`, `expanded`, `disabled`, `required`, `invalid`,
    /// `focused`, `level=2`, ...
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub states: Vec<String>,
    /// What a control holds: the text typed, the option chosen.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub value: String,
    /// An input's type when it is not plain text (`email`, `search`, `file`).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub kind: String,
    /// Readable class tokens, only on a node with no name of its own.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub hint: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub href: String,
}

impl PageNode {
    /// Whether a person acts on the node.
    pub fn is_control(&self) -> bool {
        CONTROL_ROLES.contains(&self.role.as_str())
    }

    pub fn is_text(&self) -> bool {
        self.role == "text"
    }

    /// Whether the node has no box at all (an option of a closed native list, say).
    fn boxless(&self) -> bool {
        self.w <= 0.0 && self.h <= 0.0
    }

    /// The line the model reads.
    fn line(&self) -> String {
        if self.is_text() {
            return format!("{}\"{}\"", indent(self.depth), self.name);
        }
        let mut parts = vec![format!("{}[{}]", self.role, self.id)];
        if !self.name.is_empty() {
            parts.push(format!("\"{}\"", self.name));
        }
        if !self.kind.is_empty() {
            parts.push(format!("type={}", self.kind));
        }
        if !self.value.is_empty() {
            parts.push(format!("value=\"{}\"", self.value));
        }
        if !self.states.is_empty() {
            parts.push(self.states.join(" "));
        }
        if !self.hint.is_empty() {
            parts.push(format!("class={}", self.hint));
        }
        if !self.boxless() {
            parts.push(format!("@{:.0},{:.0} {:.0}x{:.0}", self.x, self.y, self.w, self.h));
        }
        format!("{}{}", indent(self.depth), parts.join(" "))
    }
}

fn indent(depth: u32) -> String {
    "  ".repeat(depth.min(MAX_INDENT) as usize)
}

/// One screen's worth of the page outside the view, summed up.
#[derive(Default)]
struct Band {
    controls: usize,
    headings: Vec<String>,
    names: Vec<String>,
}

impl PageMap {
    /// How many controls the map holds.
    pub fn controls(&self) -> usize {
        self.nodes.iter().filter(|n| n.is_control()).count()
    }

    /// Whether each node is in view: a control when its centre is, text when any of it is, a
    /// node with no box when its parent is.
    fn in_view(&self, viewport: &Viewport) -> Vec<bool> {
        let top = viewport.scroll_y;
        let bottom = viewport.scroll_y + viewport.height as f64;
        let mut seen = Vec::with_capacity(self.nodes.len());
        // The nearest line above at each depth, to find a node's parent.
        let mut parents: Vec<bool> = Vec::new();
        for node in &self.nodes {
            parents.truncate(node.depth as usize);
            let shown = if node.boxless() {
                parents.last().copied().unwrap_or(true)
            } else if node.is_text() {
                node.y + node.h > top && node.y < bottom
            } else {
                let centre = node.y + node.h / 2.0;
                centre >= top && centre < bottom
            };
            seen.push(shown);
            parents.push(shown);
        }
        seen
    }

    /// The map as the model reads it, within the default budget.
    pub fn text(&self, viewport: &Viewport) -> String {
        self.text_within(viewport, BUDGET)
    }

    /// The map as the model reads it: the view, then a minimap of the rest, within `budget`
    /// bytes. Over budget, text lines go first, then the minimap is cut short; controls in view
    /// are always kept.
    pub fn text_within(&self, viewport: &Viewport, budget: usize) -> String {
        let shown = self.in_view(viewport);
        let top = viewport.scroll_y;
        let bottom = viewport.scroll_y + viewport.height as f64;
        let header = format!("VIEW y={top:.0}..{bottom:.0} of {:.0}", viewport.page_height);
        let in_view: Vec<&PageNode> = self.nodes.iter().zip(&shown).filter(|(_, seen)| **seen).map(|(node, _)| node).collect();
        let mut view: Vec<(bool, String)> = fold(&in_view);
        let height = (viewport.height as f64).max(1.0);
        let mut bands: std::collections::BTreeMap<i64, Band> = std::collections::BTreeMap::new();
        for (node, &seen) in self.nodes.iter().zip(&shown) {
            if seen || node.is_text() || node.boxless() {
                continue;
            }
            let band = bands.entry((node.y / height).floor() as i64).or_default();
            if node.is_control() {
                band.controls += 1;
                let name = cut(&node.name, MINIMAP_NAME_CHARS);
                if !name.is_empty() && band.names.len() < MINIMAP_NAMES && !band.names.contains(&name) {
                    band.names.push(name);
                }
            } else if node.role == "heading" && band.headings.len() < MINIMAP_HEADINGS {
                band.headings.push(cut(&node.name, MINIMAP_HEADING_CHARS));
            }
        }
        let mut minimap: Vec<String> = bands
            .iter()
            .filter(|(_, band)| band.controls > 0 || !band.headings.is_empty())
            .map(|(i, band)| {
                let mut line = format!("  y={:.0}..{:.0}  {} controls", *i as f64 * height, (*i + 1) as f64 * height, band.controls);
                if !band.headings.is_empty() {
                    line.push_str(&format!("  headings: {}", quoted(&band.headings)));
                }
                if !band.names.is_empty() {
                    line.push_str(&format!("  e.g. {}", quoted(&band.names)));
                }
                line
            })
            .collect();

        let size = |view: &[(bool, String)], minimap: &[String]| header.len() + view.iter().map(|(_, l)| l.len() + 1).sum::<usize>() + minimap.iter().map(|l| l.len() + 1).sum::<usize>() + 8;
        let mut left_out = 0;
        // Text lines go first, from the bottom of the view up.
        while size(&view, &minimap) > budget {
            match view.iter().rposition(|(text, _)| *text) {
                Some(i) => {
                    view.remove(i);
                    left_out += 1;
                }
                None => break,
            }
        }
        while size(&view, &minimap) > budget && minimap.len() > MIN_MINIMAP_LINES {
            minimap.pop();
            left_out += 1;
        }
        let mut out = header;
        for (_, line) in &view {
            out.push('\n');
            out.push_str(line);
        }
        if !minimap.is_empty() {
            out.push_str("\nMINIMAP");
            for line in &minimap {
                out.push('\n');
                out.push_str(line);
            }
        }
        if left_out > 0 {
            out.push_str(&format!("\n({left_out} lines left out for room)"));
        }
        out
    }
}

/// The lines of the view, with runs of blocks of the same shape folded: a list of results is
/// many cards alike, and the model needs the first few whole and the rest one line each, with
/// the number to act on. A block is a list item with what is under it, or, with no list round
/// them, one period of a run of nodes whose roles repeat.
fn fold(nodes: &[&PageNode]) -> Vec<(bool, String)> {
    let blocks = blocks_of(nodes);
    let mut out = Vec::new();
    let mut i = 0;
    while i < blocks.len() {
        // How many blocks from here have the same shape as this one.
        let shape = &blocks[i].shape;
        let mut run = 1;
        while i + run < blocks.len() && blocks[i + run].shape == *shape && shape.len() > 1 {
            run += 1;
        }
        if run < FOLD_AFTER {
            for block in &blocks[i..i + run] {
                out.extend(block.nodes.iter().map(|node| (node.is_text(), node.line())));
            }
        } else {
            for (k, block) in blocks[i..i + run].iter().enumerate() {
                if k < FULL_BLOCKS {
                    out.extend(block.nodes.iter().map(|node| (node.is_text(), node.line())));
                } else {
                    out.push((false, block.folded()));
                }
            }
        }
        i += run;
    }
    out
}

/// A block of the view: nodes that go together, and the shape they make.
struct Block<'a> {
    nodes: Vec<&'a PageNode>,
    shape: Vec<&'a str>,
}

impl Block<'_> {
    /// The block in one line: its first control, its texts with a number in them (a price, a
    /// rating), and how many more controls it holds.
    fn folded(&self) -> String {
        let depth = self.nodes.first().map(|n| n.depth).unwrap_or(0);
        let mut parts: Vec<String> = Vec::new();
        let mut controls = 0;
        // The texts with a number in them, prices first: what tells the cards apart.
        let mut texts: Vec<&str> = self.nodes.iter().filter(|n| n.is_text() && n.name.chars().any(|c| c.is_ascii_digit())).map(|n| n.name.as_str()).collect();
        texts.sort_by_key(|t| !t.contains(['$', '£', '€', '¥', '₩']));
        for node in &self.nodes {
            if node.is_control() {
                controls += 1;
                if controls == 1 {
                    parts.push(format!("{}[{}]{}", node.role, node.id, if node.name.is_empty() { String::new() } else { format!(" \"{}\"", node.name) }));
                }
            }
        }
        parts.extend(texts.iter().take(FOLDED_TEXTS).map(|t| format!("\"{t}\"")));
        if controls > 1 {
            parts.push(format!("(+{} controls)", controls - 1));
        }
        format!("{}· {}", indent(depth), parts.join("  "))
    }
}

/// Cuts the view into blocks: each list item with what is under it is one; a run of nodes with
/// roles that repeat with a period is cut at that period; anything else is a block of its own.
fn blocks_of<'a>(nodes: &[&'a PageNode]) -> Vec<Block<'a>> {
    let mut out: Vec<Block<'a>> = Vec::new();
    let mut i = 0;
    while i < nodes.len() {
        if nodes[i].role == "listitem" {
            let depth = nodes[i].depth;
            let mut end = i + 1;
            while end < nodes.len() && nodes[end].depth > depth {
                end += 1;
            }
            out.push(Block { nodes: nodes[i..end].to_vec(), shape: nodes[i..end].iter().map(|n| n.role.as_str()).collect() });
            i = end;
            continue;
        }
        // A run from here whose roles repeat with the shortest period that holds for at least
        // FOLD_AFTER periods.
        let roles: Vec<&str> = nodes[i..].iter().map(|n| n.role.as_str()).collect();
        let found = (2..=MAX_PERIOD.min(roles.len() / FOLD_AFTER)).find(|&p| {
            roles[p..].iter().zip(&roles).take(p * (FOLD_AFTER - 1)).all(|(a, b)| a == b) && roles[0] != "text" && nodes[i].depth <= nodes[i + p].depth
        });
        match found {
            Some(p) => {
                // As many whole periods as hold, cut one block each.
                let mut periods = 1;
                while (periods + 1) * p <= roles.len() && roles[periods * p..(periods + 1) * p] == roles[..p] {
                    periods += 1;
                }
                for k in 0..periods {
                    let slice = &nodes[i + k * p..i + (k + 1) * p];
                    out.push(Block { nodes: slice.to_vec(), shape: slice.iter().map(|n| n.role.as_str()).collect() });
                }
                i += periods * p;
            }
            None => {
                out.push(Block { nodes: vec![nodes[i]], shape: vec![nodes[i].role.as_str()] });
                i += 1;
            }
        }
    }
    out
}

fn cut(text: &str, max: usize) -> String {
    text.chars().take(max).collect()
}

fn quoted(names: &[String]) -> String {
    names.iter().map(|n| format!("\"{n}\"")).collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn viewport(scroll_y: f64) -> Viewport {
        Viewport { width: 1280, height: 800, scroll_y, page_height: 1170.0, ..Default::default() }
    }

    /// The map of a page like GOV.UK's visa check, as the reference builder made it from the
    /// accessibility tree and the DOM snapshot of a copy of the page.
    fn govuk() -> PageMap {
        serde_json::from_str(include_str!("fixtures/govuk.page.json")).unwrap()
    }

    #[test]
    fn the_map_reads_as_lines_with_live_state_and_a_minimap() {
        let map = govuk();
        let text = map.text(&viewport(0.0));
        assert!(text.starts_with("VIEW y=0..800 of 1170\n"), "{text}");
        // The name comes from the alt of the image in the link; the state is the live one.
        assert!(text.contains("link[2] \"GOV.UK\" @30,12 77x17"), "{text}");
        assert!(text.contains("    radio[10] \"Work, academic visit or business\" value=\"work\" checked @181,224 13x13"), "{text}");
        assert!(text.contains("radio[12] \"Transit (passing through the UK)\" value=\"transit\" disabled"), "{text}");
        // A select's options have no box: they follow their list into the view.
        assert!(text.contains("combobox[15] \"Select a country\" value=\"United States\" hasPopup=menu @279,335 103x19\n    option[16] \"Choose\"\n    option[17] \"United States\" selected\n"), "{text}");
        // A pressed div with no role is a clickable, named from its text.
        assert!(text.contains("clickable[19] \"Healthcare worker visa Read about eligibility\" class=card"), "{text}");
        // The footer is out of view: one line for its screen.
        assert!(text.ends_with("MINIMAP\n  y=800..1600  5 controls  headings: \"Support links\"  e.g. \"Help\" \"Cookies\" \"Contact\" \"Terms and conditions\""), "{text}");
        assert_eq!(map.controls(), 20);
    }

    #[test]
    fn scrolling_moves_the_view_and_the_minimap() {
        let map = govuk();
        let text = map.text(&viewport(600.0));
        assert!(text.starts_with("VIEW y=600..1400 of 1170\n"));
        assert!(text.contains("link[27] \"Help\""), "{text}");
        assert!(!text.contains("radio[10]"), "{text}");
        assert!(text.contains("MINIMAP\n  y=0..800  "), "{text}");
    }

    #[test]
    fn a_frame_hangs_under_its_line_in_page_coordinates() {
        let map: PageMap = serde_json::from_str(include_str!("fixtures/frame.page.json")).unwrap();
        let text = map.text(&Viewport { width: 1280, height: 800, page_height: 800.0, ..Default::default() });
        assert!(text.contains("frame[3] \"Payment\" @300,150 400x300\n  textbox[4] \"Card number\" @404,170 185x21\n  button[5] \"Pay $10\""), "{text}");
        assert_eq!(map.nodes[3].frame, 1);
    }

    #[test]
    fn a_run_of_cards_alike_is_folded_after_the_first_two() {
        let map: PageMap = serde_json::from_str(include_str!("fixtures/shop.page.json")).unwrap();
        let text = map.text(&Viewport { width: 1280, height: 800, page_width: 1280.0, page_height: 1600.0, ..Default::default() });
        // The first two cards whole, the rest one line each with the number to act on.
        assert!(text.contains("link[13] \"Acer Aspire 5 15.6in Laptop (1)\" @29,289 274x120\nlink[14] \"Acer Aspire 5 15.6in Laptop (1)\" @29,427 274x22\n\"4.3 out of 5 stars\"\n  \"★★★★☆\"\n  \"(1,023)\"\n\"$199.00\"\nbutton[19] \"Add to cart\""), "{text}");
        assert!(text.contains("· link[27] \"Lenovo IdeaPad 3 (3)\"  \"$214.00\"  \"4.3 out of 5 stars\"  (+2 controls)"), "{text}");
        assert!(text.contains("· link[34] \"ASUS Vivobook 16 (4)\""), "{text}");
        assert!(!text.contains("button[33]"), "{text}");
        // The controls above the list are untouched.
        assert!(text.contains("searchbox[2] \"Search Shopmart\" value=\"laptop\""), "{text}");
        let lines = text.lines().count();
        assert!(lines < 60, "{lines} lines:\n{text}");
    }

    #[test]
    fn over_budget_text_goes_first_then_the_minimap_and_controls_stay() {
        let map = govuk();
        let full = map.text(&viewport(0.0));
        let small = map.text_within(&viewport(0.0), full.len() - 40);
        assert!(small.len() <= full.len() - 40 + 40, "{small}");
        assert!(!small.contains("\"You need a visa if you are coming for more than 6 months.\""), "{small}");
        assert!(small.contains("button[20] \"Continue\""), "{small}");
        assert!(small.ends_with("lines left out for room)"), "{small}");
        let tiny = map.text_within(&viewport(0.0), 1);
        assert!(tiny.contains("button[20] \"Continue\""));
    }
}
