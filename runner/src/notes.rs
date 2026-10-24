//! What earlier runs learned of a site, kept between runs: the address of the page that
//! answered a request like this one, a control that mattered, a trap. A run is given the notes
//! of its site with the task (the intake reads them too, so it can start on the page that
//! answered last time); at its end the model writes what the next run on the site should know
//! (`learned`), and that is merged here. One file, by site, in the app's data folder.

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

/// The most notes kept per site, newest first.
pub const MAX_NOTES: usize = 12;
/// The most notes given to one run.
pub const NOTES_SHOWN: usize = 8;
/// The most characters one note keeps.
const MAX_NOTE_CHARS: usize = 240;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Note {
    pub text: String,
    /// The day it was learned, as `2026-10-23`, and the request it was learned on.
    #[serde(default)]
    pub at: String,
    #[serde(default)]
    pub goal: String,
}

/// The notes of every site, by site.
pub type Store = BTreeMap<String, Vec<Note>>;

/// The site of an address as a person names it: the last two labels of its host
/// (`qatarairways.com` for `https://www.qatarairways.com/en/baggage/allowance.html`). Empty
/// when the address has no host.
pub fn site_of(url: &str) -> String {
    let rest = url.trim().split("://").nth(1).unwrap_or("");
    let host = rest.split(['/', '?', '#']).next().unwrap_or("").split('@').next_back().unwrap_or("");
    let host = host.split(':').next().unwrap_or("").trim().to_lowercase();
    let labels: Vec<&str> = host.split('.').filter(|l| !l.is_empty()).collect();
    if labels.len() < 2 {
        return String::new();
    }
    labels[labels.len() - 2..].join(".")
}

/// The store as the file holds it; an unreadable or missing file is an empty store.
pub fn load(path: &Path) -> Store {
    std::fs::read_to_string(path).ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default()
}

/// Writes the store, whole, through a temporary file beside it.
pub fn save(path: &Path, store: &Store) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("make {}: {e}", parent.display()))?;
    }
    let text = serde_json::to_string_pretty(store).map_err(|e| format!("encode the site notes: {e}"))?;
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, text).map_err(|e| format!("write {}: {e}", temporary.display()))?;
    std::fs::rename(&temporary, path).map_err(|e| format!("replace {}: {e}", path.display()))
}

/// The notes to give a run on the site, newest first.
pub fn for_site(store: &Store, site: &str) -> Vec<String> {
    store.get(site).map(|notes| notes.iter().take(NOTES_SHOWN).map(|n| n.text.clone()).collect()).unwrap_or_default()
}

/// Keeps what a run learned of the site: each line once (a line already known moves to the
/// front), newest first, at most `MAX_NOTES`. Says how many lines were new.
pub fn learn(store: &mut Store, site: &str, learned: &[String], goal: &str, at: &str) -> usize {
    if site.is_empty() {
        return 0;
    }
    let notes = store.entry(site.to_string()).or_default();
    let mut added = 0;
    for line in learned.iter().rev() {
        let text: String = line.split_whitespace().collect::<Vec<_>>().join(" ");
        let text: String = text.chars().take(MAX_NOTE_CHARS).collect();
        if text.is_empty() {
            continue;
        }
        if let Some(at_index) = notes.iter().position(|n| n.text.eq_ignore_ascii_case(&text)) {
            let known = notes.remove(at_index);
            notes.insert(0, known);
            continue;
        }
        notes.insert(0, Note { text, at: at.to_string(), goal: goal.lines().next().unwrap_or("").chars().take(MAX_NOTE_CHARS).collect() });
        added += 1;
    }
    notes.truncate(MAX_NOTES);
    added
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_site_is_the_last_two_labels_of_the_host() {
        assert_eq!(site_of("https://www.qatarairways.com/en/baggage/allowance.html"), "qatarairways.com");
        assert_eq!(site_of("https://discussions.flightaware.com/t/the-banter-thread/4412"), "flightaware.com");
        assert_eq!(site_of("http://user@web.archive.org:8080/web/2005/apple.com"), "archive.org");
        assert_eq!(site_of("https://localhost/"), "");
        assert_eq!(site_of("not an address"), "");
    }

    #[test]
    fn notes_are_kept_once_newest_first_and_capped_and_survive_the_file() {
        let mut store = Store::new();
        assert_eq!(learn(&mut store, "qatarairways.com", &["The baggage table is at /en/baggage/allowance.html".into(), "  Economy  weights are per fare type ".into()], "find the baggage weight", "2026-10-23"), 2);
        // A run's lines stay in its order, ahead of what was known before.
        assert_eq!(for_site(&store, "qatarairways.com"), vec!["The baggage table is at /en/baggage/allowance.html", "Economy weights are per fare type"]);
        // A line already known is not added twice; it moves to the front.
        assert_eq!(learn(&mut store, "qatarairways.com", &["the baggage table is at /en/baggage/allowance.html".into()], "again", "2026-10-24"), 0);
        assert_eq!(for_site(&store, "qatarairways.com")[0], "The baggage table is at /en/baggage/allowance.html");
        assert_eq!(store["qatarairways.com"][0].at, "2026-10-23");
        for i in 0..20 {
            learn(&mut store, "qatarairways.com", &[format!("note {i}")], "g", "2026-10-25");
        }
        assert_eq!(store["qatarairways.com"].len(), MAX_NOTES);
        assert_eq!(for_site(&store, "qatarairways.com").len(), NOTES_SHOWN);
        assert!(for_site(&store, "other.com").is_empty());
        assert_eq!(learn(&mut store, "", &["x".into()], "g", "d"), 0);
        let dir = std::env::temp_dir().join(format!("acorn-notes-{}", std::process::id()));
        let path = dir.join("site-notes.json");
        save(&path, &store).unwrap();
        assert_eq!(load(&path), store);
        assert!(load(&dir.join("missing.json")).is_empty());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
