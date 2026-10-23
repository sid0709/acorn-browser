//! One run of one task: the task, the profile it acts as, the model's memory, and the run's state.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::hash::{BuildHasher, Hasher, RandomState};
use std::sync::Arc;
use std::time::{Instant, SystemTime};

use crate::action::{Action, Batch};
use crate::change::Signature;
use crate::focus::FocusTarget;
use crate::gate::{CommitState, FieldHold, ListHold};
use crate::map::{Coverage, Settled};
use crate::memory::Memory;
use crate::observe::{ActionResult, Viewport};
use crate::ports::Usage;
use crate::profile::Profile;
use crate::review::{Expectation, Reviews};
use crate::run::{Question, Status, StopInfo};
use crate::task::{Allowance, Irreversible, Task};
use crate::todo::FieldState;
use crate::trace::{CheckTrace, ModelCall};

/// One application of the harness to one task, from the first look to the end.
#[derive(Debug)]
pub struct Session {
    pub id: String,
    pub task: Task,
    pub profile: Profile,
    pub created: SystemTime,
    /// When the run last did anything, for expiring idle sessions.
    pub touched: Instant,
    /// When the harness got the look being answered, for the trace's timing.
    pub step_started: SystemTime,
    /// The decision model's calls made since the last trace entry, which carries them; and the
    /// last checkpoint as the trace shows it, until an entry carries it.
    pub pending_calls: Vec<ModelCall>,
    pub last_check: Option<CheckTrace>,
    /// Counts every step asked, the failed ones included; names the trace entries.
    pub seq: u32,
    /// Counts the steps the model took.
    pub step: u32,
    /// The most steps the run may take so far. Going on after the limit adds a whole budget, so
    /// a run the person is still helping is not cut off again at once.
    pub step_limit: u32,
    /// Set once a step ended the run; `stopped_for` is why, in the words of the step, and
    /// `last_status` and `last_stop` how that step ended it.
    pub finished: bool,
    pub stopped_for: String,
    pub last_status: Status,
    pub last_stop: Option<StopInfo>,
    /// What the model said it assumed for the person, each line once, for the report.
    pub assumed: Vec<String>,
    /// How many "done" answers were sent back because the screen did not confirm them; how many
    /// stops for the person were sent back to finish the page first; how many stops for a human
    /// check were sent back because the screen showed none; and the last stop sent back for the
    /// fields read as empty.
    pub done_passes: u32,
    pub stop_passes: u32,
    pub captcha_passes: u32,
    pub field_hold: FieldHold,
    /// Set when a "done" was sent back on the page the run is on: the next plan may not leave
    /// that page (no back, no navigate), since the proof belongs on it.
    pub leave_held: bool,
    /// The click that sends the page, as the last plan kept it; how many times a send was held
    /// on this page for the to-do list; and that the page refused the last send, so the next is
    /// held for one look.
    pub commit: CommitState,
    pub list_hold: ListHold,
    pub send_refused: bool,
    /// What the person wrote since the model last looked, oldest first.
    pub inbox: Vec<String>,
    /// Every question the run asked the person, with the answer when one came; the ones the gate
    /// asked this step, for the step to carry; and the kinds of action it already asked leave for.
    pub questions: Vec<Question>,
    pub asked_now: Vec<Question>,
    pub asked_for: BTreeSet<Irreversible>,
    /// The kind of action the person reserved for themselves that the gate held on this page:
    /// when nothing else is left, the run ends ready for them.
    pub held_reserved: Option<Irreversible>,
    /// The model's own notes to itself, carried from step to step and shown with each look.
    pub memo: String,
    /// The model's latest line for the person, shown again while its plan runs on without it.
    pub message: String,
    /// What the models have cost the run so far.
    pub usage: Usage,
    /// Things the model is told on its next look, about what its plan did.
    pub notes: Vec<String>,
    /// The run's history of turns, folded and compacted as it grows.
    pub memory: Memory,
    /// Results of actions sent since the model last looked, which may be several batches.
    pub carried: Vec<ActionResult>,
    /// What the model planned and has not yet been sent, one batch per check; and what of the
    /// plan has been sent, in order, which the reviews are built from.
    pub plan: Vec<Batch>,
    pub sent_actions: Vec<Action>,
    /// Actions the harness held back since the model last looked, with why: they go out with the
    /// next step as dropped, so the trace shows them.
    pub withheld: Vec<String>,
    /// The points the checker has doubted on this page (by position and label): a doubt it has
    /// raised before is not raised again, and does not ask for another survey.
    pub doubted: BTreeSet<String>,
    pub doubted_url: String,
    /// What the screen should show after the batch just sent, until that batch is checked.
    pub verify: String,
    /// The actions of the model's latest plan by id, to match a result to its action.
    pub by_id: HashMap<String, Action>,
    /// How many actions the model's latest plan held, how many of them went out, and in how
    /// many batches.
    pub planned: usize,
    pub sent: usize,
    pub parts: usize,
    /// Waits in a row for a loading page, with no model call.
    pub load_waits: u32,
    /// Set once a check failed: the rest of the run goes without them.
    pub checks_off: bool,
    /// The window as the last look saw it, to check the pictures sent mid-batch against.
    pub viewport: Viewport,
    /// Counts the plans the model has made, and what the current one fills in, by zone, for the
    /// reviews of its zones; the page it was made on, and where the page was scrolled then.
    pub plan_gen: u32,
    pub expect: BTreeMap<u32, Vec<Expectation>>,
    pub expect_url: String,
    pub plan_scroll_y: f64,
    /// The fields whose fill did not verify since the model last looked, for the survey that
    /// follows to show whole.
    pub retry: Vec<FocusTarget>,
    /// The reviews running beside the plan, shared with the threads that run them; by zone,
    /// whether the photo of each zone of the plan being carried out showed every field as
    /// planned; and what the reviews taken in since the last look found wrong, for its note.
    pub reviews: Arc<Reviews>,
    pub reviewed: BTreeMap<u32, bool>,
    pub review_wrong: Vec<String>,
    /// The labels of the fields the reviews found filled as planned on `confirmed_url`, for the
    /// stretches settled row by row.
    pub confirmed: Vec<String>,
    pub confirmed_url: String,
    /// Asks for the next look to be a survey: something was found that the model must see the
    /// whole page again to put right.
    pub survey_again: bool,
    /// The form's to-do list as the model read it on the page's last survey, kept up to date by
    /// the reviews; the page it is of, and whether the browser has not been sent it since it
    /// changed.
    pub fields: Vec<FieldState>,
    pub fields_url: String,
    pub fields_changed: bool,
    /// Counts the changes to the list, so a wait for a newer list (`Agent::wait_fields`) knows one.
    pub fields_version: u32,
    /// The parts of the page the model will not come back to, and what the run has looked at on
    /// the page it is on.
    pub settled: Settled,
    pub cover: Coverage,
    /// The previous screenshot's signature, for telling whether the page changed.
    pub last_signature: Option<Signature>,
    /// Steps in a row where the screen did not change.
    pub stale: u32,
    /// Model steps in a row whose every action failed the same way, and that failure. A plan
    /// refused whole, step after step, is a loop the model cannot see out of.
    pub failed_streak: u32,
    pub last_failure: String,
}

impl Session {
    pub fn new(task: Task, profile: Profile) -> Self {
        let step_limit = task.persistence.max_steps;
        Session {
            id: new_id(),
            task,
            profile,
            created: SystemTime::now(),
            touched: Instant::now(),
            step_started: SystemTime::now(),
            pending_calls: Vec::new(),
            last_check: None,
            seq: 0,
            step: 0,
            step_limit,
            finished: false,
            stopped_for: String::new(),
            last_status: Status::Working,
            last_stop: None,
            assumed: Vec::new(),
            done_passes: 0,
            stop_passes: 0,
            captcha_passes: 0,
            field_hold: FieldHold::default(),
            leave_held: false,
            commit: CommitState::default(),
            list_hold: ListHold::default(),
            send_refused: false,
            inbox: Vec::new(),
            questions: Vec::new(),
            asked_now: Vec::new(),
            asked_for: BTreeSet::new(),
            held_reserved: None,
            memo: String::new(),
            message: String::new(),
            usage: Usage::default(),
            notes: Vec::new(),
            memory: Memory::default(),
            carried: Vec::new(),
            plan: Vec::new(),
            verify: String::new(),
            by_id: HashMap::new(),
            planned: 0,
            sent: 0,
            parts: 0,
            load_waits: 0,
            checks_off: false,
            viewport: Viewport::default(),
            plan_gen: 0,
            sent_actions: Vec::new(),
            withheld: Vec::new(),
            doubted: BTreeSet::new(),
            doubted_url: String::new(),
            expect: BTreeMap::new(),
            expect_url: String::new(),
            plan_scroll_y: 0.0,
            retry: Vec::new(),
            reviews: Arc::new(Reviews::default()),
            reviewed: BTreeMap::new(),
            review_wrong: Vec::new(),
            confirmed: Vec::new(),
            confirmed_url: String::new(),
            survey_again: false,
            fields: Vec::new(),
            fields_url: String::new(),
            fields_changed: false,
            fields_version: 0,
            settled: Settled::default(),
            cover: Coverage::default(),
            last_signature: None,
            stale: 0,
            failed_streak: 0,
            last_failure: String::new(),
        }
    }

    /// Lets a run that reached its limit go on with a whole budget more.
    pub fn extend(&mut self) {
        self.step_limit += self.task.persistence.max_steps;
        self.finished = false;
    }

    /// Whether the run has used its steps.
    pub fn at_step_limit(&self) -> bool {
        self.step >= self.step_limit
    }

    pub fn touch(&mut self) {
        self.touched = Instant::now();
    }

    /// Sets what the run may do for one kind of action that cannot be taken back, answers the
    /// question that asked, and tells the model.
    pub(crate) fn allow(&mut self, kind: Irreversible, allowance: Allowance) {
        self.task.allowances.insert(kind, allowance);
        for question in self.questions.iter_mut().filter(|q| q.allows == Some(kind) && q.answer.is_none()) {
            question.answer = Some(if allowance == Allowance::Auto { "yes" } else { "no" }.to_string());
        }
        self.inbox.push(match allowance {
            Allowance::Auto => format!("The person allows you to {} on their behalf: plan that click again, on its own, when the page is complete.", kind.verb()),
            _ => format!("The person does not allow the run to {}: never press that click. Do everything else, then report done, and the run ends ready for them.", kind.verb()),
        });
    }

    /// Drops the model's plan and the count of it: nothing of it is sent or checked again.
    pub fn forget_plan(&mut self) {
        self.plan.clear();
        self.sent_actions.clear();
        self.verify.clear();
        self.planned = 0;
        self.sent = 0;
        self.parts = 0;
    }
}

/// A fresh id: 128 bits from the standard library's randomly keyed hasher, as hex.
fn new_id() -> String {
    let a = RandomState::new().build_hasher().finish();
    let b = RandomState::new().build_hasher().finish();
    format!("{a:016x}{b:016x}")
}
