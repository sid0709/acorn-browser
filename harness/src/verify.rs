//! Checking what happened without blocking what happens next: a checkpoint after each batch of a
//! plan, so the next batch can run without the driving model looking again.
//!
//! The driving model plans a whole screen at once and says, at the end of each batch it is sure
//! of, what the screen should then show. A decision model (cheap and quick, answering with
//! probabilities and no prose) reads the screenshot after that batch. When the screen matches,
//! the next batch goes out without the driving model; when it does not, or something is in the
//! way, the driving model looks and decides. The driving model is the only one that ever plans
//! or recovers: the checker only says yes or no.

use crate::ports::{Decider, Decision, Error, Part, Question, Verdicts};

/// The keys the checker's three answers come back under.
const ASK_MATCHES: &str = "matches";
const ASK_BLOCKED: &str = "blocked";
const ASK_LOADING: &str = "loading";

/// What the checker made of a screenshot: the probability of each of the three questions.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Verdict {
    pub matches: f64,
    pub blocked: f64,
    pub loading: f64,
}

/// The thresholds that turn a verdict into an outcome.
#[derive(Clone, Copy, Debug)]
pub struct Thresholds {
    /// At or above this, the screen matches what was expected.
    pub match_at: f64,
    /// Above this, something is in the way.
    pub blocked_over: f64,
    /// Above this, the page may still be loading.
    pub loading_over: f64,
    /// At or above this, the page is loading enough to wait for it.
    pub loading_wait_at: f64,
    /// The most waits in a row for a loading page before the model looks instead.
    pub max_load_waits: u32,
}

impl Default for Thresholds {
    fn default() -> Self {
        Thresholds { match_at: 0.9, blocked_over: 0.2, loading_over: 0.3, loading_wait_at: 0.7, max_load_waits: 4 }
    }
}

/// What a checked screen means for the plan.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The screen shows what was expected: run the next batch without the model.
    Continue,
    /// The page is still loading: wait and check again.
    Wait,
    /// Give the screenshot to the driving model, for this reason.
    Look(String),
}

/// Asks the checker whether a screenshot shows what the model expected, whether something is in
/// the way, and whether the page is still loading.
pub fn look(decider: &(dyn Decider + Send + Sync), screenshot: &str, expect: &str) -> Result<(Verdict, Verdicts), Error> {
    let mut questions = std::collections::BTreeMap::new();
    questions.insert(
        ASK_MATCHES.to_string(),
        Question::yes_no(format!("Someone has just typed and clicked on this page. They expected the page to now show: {expect}. Does the screenshot show that?")),
    );
    questions.insert(
        ASK_BLOCKED.to_string(),
        Question::yes_no("Is the page blocked by something other than the content itself: a popup, dialog or overlay covering it, a CAPTCHA, a sign-in wall, or a page-level error such as 'something went wrong'? A small validation message beside a field does not count."),
    );
    questions.insert(
        ASK_LOADING.to_string(),
        Question::yes_no("Is the page still loading or changing: a spinner, a progress bar, a blank or half-drawn page, or a control that says it is still working?"),
    );
    let state = vec![Part::Text("A screenshot of a web page the browser is on.".to_string()), Part::Image(screenshot.to_string())];
    let verdicts = decider.decide(Decision { state, questions })?;
    let answer = |key: &str| verdicts.yes(key).ok_or_else(|| Error::new(crate::ports::ErrorKind::Other, format!("the checker gave no answer to {key:?}")));
    let verdict = Verdict { matches: answer(ASK_MATCHES)?, blocked: answer(ASK_BLOCKED)?, loading: answer(ASK_LOADING)? };
    Ok((verdict, verdicts))
}

/// What a verdict means: carry on with the plan, wait for the page, or give the screenshot to
/// the driving model.
pub fn judge(v: Verdict, t: &Thresholds, load_waits: u32) -> Outcome {
    if v.matches >= t.match_at && v.blocked <= t.blocked_over && v.loading <= t.loading_over {
        Outcome::Continue
    } else if v.loading >= t.loading_wait_at && load_waits < t.max_load_waits {
        Outcome::Wait
    } else if v.blocked > t.blocked_over {
        Outcome::Look(format!("something may be in the way ({:.2})", v.blocked))
    } else if v.loading > t.loading_over {
        Outcome::Look(format!("the page may still be loading ({:.2})", v.loading))
    } else {
        Outcome::Look(format!("the screen may not show what was expected ({:.2})", v.matches))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_clean_match_continues_and_doubt_looks() {
        let t = Thresholds::default();
        assert_eq!(judge(Verdict { matches: 0.95, blocked: 0.0, loading: 0.0 }, &t, 0), Outcome::Continue);
        assert_eq!(judge(Verdict { matches: 0.1, blocked: 0.0, loading: 0.9 }, &t, 0), Outcome::Wait);
        // Too many waits already: look instead.
        assert!(matches!(judge(Verdict { matches: 0.1, blocked: 0.0, loading: 0.9 }, &t, 4), Outcome::Look(_)));
        assert!(matches!(judge(Verdict { matches: 0.1, blocked: 0.9, loading: 0.0 }, &t, 0), Outcome::Look(_)));
        assert!(matches!(judge(Verdict { matches: 0.1, blocked: 0.0, loading: 0.0 }, &t, 0), Outcome::Look(_)));
    }
}
