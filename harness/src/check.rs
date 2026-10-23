//! Checks the harness can judge itself, from the page map, with no model: whether a control is
//! checked, holds a value or has the focus, whether the page moved to an address, whether some
//! text is on the page. The model writes one on an action in DOM mode instead of a sentence,
//! and the batch after it goes on (or not) in a few microseconds.
//!
//! As the model writes them, naming a node by its number on the map it was shown:
//!
//! ```text
//! [12] checked          [12] unchecked         [12] focused         [12] gone
//! [12] value="laptop"   url~="/results"        exists "Thank you"
//! ```
//!
//! A number is only good on the map it came from: the next look numbers the page afresh. So
//! before the plan goes out, `bind` turns the number into the node's role and name
//! (`[radio "Work, academic visit or business"] checked`), which the next map is searched for.
//! A check in other words than these is not one of the harness's: the decision model reads it.

use crate::page::PageMap;

/// What the check asks of the page.
#[derive(Clone, Debug, PartialEq)]
pub enum Test {
    Checked(bool),
    Value(String),
    Focused,
    /// The node is no longer on the page (a dialog closed, a banner dismissed).
    Gone,
    /// The address holds the text.
    Url(String),
    /// Some node's name holds the text.
    Exists(String),
}

/// The node a check names, as the map it was bound on described it.
#[derive(Clone, Debug, PartialEq)]
pub struct NodeRef {
    pub role: String,
    pub name: String,
}

/// One check the harness judges.
#[derive(Clone, Debug, PartialEq)]
pub struct Check {
    /// The node named: by number before `bind`, by role and name after.
    pub node: Option<Node>,
    pub test: Test,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Node {
    Number(u32),
    Ref(NodeRef),
}

impl Check {
    /// Reads a check in the harness's words; `None` for one in the model's own.
    pub fn parse(text: &str) -> Option<Check> {
        let text = text.trim();
        if let Some(rest) = text.strip_prefix('[') {
            let end = rest.find(']')?;
            let inside = rest[..end].trim();
            let node = if let Ok(n) = inside.parse::<u32>() {
                Node::Number(n)
            } else {
                let (role, name) = inside.split_once(' ')?;
                Node::Ref(NodeRef { role: role.trim().to_string(), name: unquote(name) })
            };
            let test = rest[end + 1..].trim();
            let test = match test {
                "checked" => Test::Checked(true),
                "unchecked" | "not checked" => Test::Checked(false),
                "focused" => Test::Focused,
                "gone" => Test::Gone,
                other => Test::Value(unquote(other.strip_prefix("value")?.trim().strip_prefix('=')?)),
            };
            return Some(Check { node: Some(node), test });
        }
        let lower = text.to_ascii_lowercase();
        if let Some(rest) = lower.strip_prefix("url") {
            let rest = rest.trim_start();
            let rest = rest.strip_prefix("~=").or_else(|| rest.strip_prefix('='))?;
            return Some(Check { node: None, test: Test::Url(unquote(&text[text.len() - rest.len()..])) });
        }
        if let Some(rest) = lower.strip_prefix("exists") {
            return Some(Check { node: None, test: Test::Exists(unquote(&text[text.len() - rest.len()..])) });
        }
        None
    }

    /// The check with its node number turned into the node's role and name on `page`, so it
    /// can be judged on a later map. A check that is not the harness's, or names a node the map
    /// does not have, is returned as it was.
    pub fn bind(text: &str, page: &PageMap) -> String {
        let Some(check) = Check::parse(text) else { return text.to_string() };
        let Some(Node::Number(n)) = check.node else { return text.to_string() };
        let Some(node) = page.nodes.iter().find(|node| node.id == n) else { return text.to_string() };
        let test = match &check.test {
            Test::Checked(true) => "checked".to_string(),
            Test::Checked(false) => "unchecked".to_string(),
            Test::Focused => "focused".to_string(),
            Test::Gone => "gone".to_string(),
            Test::Value(v) => format!("value={v:?}"),
            Test::Url(_) | Test::Exists(_) => return text.to_string(),
        };
        format!("[{} {:?}] {test}", node.role, node.name)
    }

    /// Whether the page shows what the check asks: `None` when the map does not settle it (the
    /// node named is not on it, or the check still names a number).
    pub fn judge(&self, page: &PageMap, url: &str) -> Option<bool> {
        match &self.test {
            Test::Url(text) => return Some(url.to_ascii_lowercase().contains(&text.to_ascii_lowercase())),
            Test::Exists(text) => {
                let wanted = text.to_ascii_lowercase();
                return Some(page.nodes.iter().any(|node| node.name.to_ascii_lowercase().contains(&wanted)));
            }
            _ => {}
        }
        let Some(Node::Ref(wanted)) = &self.node else { return None };
        let found = page.nodes.iter().find(|node| node.role == wanted.role && same_name(&node.name, &wanted.name));
        match (&self.test, found) {
            (Test::Gone, found) => Some(found.is_none()),
            (_, None) => None,
            (Test::Checked(wanted), Some(node)) => Some(node.states.iter().any(|s| s == "checked") == *wanted),
            (Test::Focused, Some(node)) => Some(node.states.iter().any(|s| s == "focused")),
            (Test::Value(wanted), Some(node)) => Some(same_name(&node.value, wanted)),
            _ => None,
        }
    }
}

fn same_name(a: &str, b: &str) -> bool {
    a.trim().eq_ignore_ascii_case(b.trim())
}

/// The text without the quotes round it, when it has them.
fn unquote(text: &str) -> String {
    let text = text.trim();
    let inner = text.strip_prefix('"').and_then(|t| t.strip_suffix('"')).or_else(|| text.strip_prefix('\'').and_then(|t| t.strip_suffix('\'')));
    inner.unwrap_or(text).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::page::PageNode;

    fn page() -> PageMap {
        let node = |id: u32, role: &str, name: &str, states: &[&str], value: &str| PageNode {
            id,
            role: role.into(),
            name: name.into(),
            states: states.iter().map(|s| s.to_string()).collect(),
            value: value.into(),
            ..Default::default()
        };
        PageMap {
            nodes: vec![
                node(1, "heading", "What will you be doing in the UK?", &[], ""),
                node(2, "radio", "Work, academic visit or business", &["checked"], "work"),
                node(3, "radio", "Study", &[], "study"),
                node(4, "textbox", "Search", &["focused"], "laptop"),
                node(5, "button", "Continue", &[], ""),
            ],
        }
    }

    #[test]
    fn the_harness_s_checks_parse_and_the_model_s_do_not() {
        assert_eq!(Check::parse("[12] checked"), Some(Check { node: Some(Node::Number(12)), test: Test::Checked(true) }));
        assert_eq!(Check::parse("[12] value=\"laptop\""), Some(Check { node: Some(Node::Number(12)), test: Test::Value("laptop".into()) }));
        assert_eq!(Check::parse("url~=\"/results\""), Some(Check { node: None, test: Test::Url("/results".into()) }));
        assert_eq!(Check::parse("exists \"Thank you\""), Some(Check { node: None, test: Test::Exists("Thank you".into()) }));
        assert_eq!(Check::parse("[radio \"Study\"] unchecked"), Some(Check { node: Some(Node::Ref(NodeRef { role: "radio".into(), name: "Study".into() })), test: Test::Checked(false) }));
        assert_eq!(Check::parse("the Work option is selected"), None);
        assert_eq!(Check::parse("[12] wobbles"), None);
    }

    #[test]
    fn a_number_is_bound_to_the_node_and_judged_on_the_next_map() {
        let page = page();
        let bound = Check::bind("[2] checked", &page);
        assert_eq!(bound, "[radio \"Work, academic visit or business\"] checked");
        assert_eq!(Check::parse(&bound).unwrap().judge(&page, ""), Some(true));
        assert_eq!(Check::parse(&Check::bind("[3] checked", &page)).unwrap().judge(&page, ""), Some(false));
        assert_eq!(Check::parse(&Check::bind("[4] value=\"laptop\"", &page)).unwrap().judge(&page, ""), Some(true));
        assert_eq!(Check::parse(&Check::bind("[4] focused", &page)).unwrap().judge(&page, ""), Some(true));
        assert_eq!(Check::parse("[button \"Accept cookies\"] gone").unwrap().judge(&page, ""), Some(true));
        assert_eq!(Check::parse("[button \"Continue\"] gone").unwrap().judge(&page, ""), Some(false));
        // A node the map no longer has settles nothing but "gone".
        assert_eq!(Check::parse("[button \"Accept cookies\"] checked").unwrap().judge(&page, ""), None);
        assert_eq!(Check::parse("[2] checked").unwrap().judge(&page, ""), None);
        // A number the map does not have, or a check in the model's words, is left as it was.
        assert_eq!(Check::bind("[99] checked", &page), "[99] checked");
        assert_eq!(Check::bind("the list is open", &page), "the list is open");
        assert_eq!(Check::parse("url ~= /Results").unwrap().judge(&page, "https://shop.test/results?q=1"), Some(true));
        assert_eq!(Check::parse("exists \"continue\"").unwrap().judge(&page, ""), Some(true));
        assert_eq!(Check::parse("exists \"Thank you\"").unwrap().judge(&page, ""), Some(false));
    }
}
