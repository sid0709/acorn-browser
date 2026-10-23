# harness

A general-purpose agent harness for a browser that does any task given in chat. Pure image
based: the browser sends a screenshot, the harness answers with the next actions. It is the brain
of Acorn Browser; the browser (the app, over its agent socket) is the hands and eyes.

```bash
cargo build                    # no warnings
cargo test
cargo run --example fake_run   # one whole run against a scripted model and a drawn page
```

## The idea

Two models, and the harness between them and the browser:

- **The driving model** plans and recovers. It is the only one that ever decides what to do. It
  reads a screenshot (or a survey of the whole page) and answers with a status, a line for the
  person, and a plan of actions, each with the control it aims at and what the screen should show
  once it has run.
- **The decision model** answers yes-or-no questions with probabilities and no prose, cheaply and
  quickly: does the screen show what the plan expected, does the field show what was typed, is
  the point on the control the label belongs to, does the page show the task done. It never
  plans; it only lets a plan go on without the driving model, or hurries a correction.
- **The harness** observes, verifies, remembers, and decides when the run is done, stuck, or
  needs the person. Verification never blocks execution: a plan goes on while the last batch is
  being checked, and reviews run on their own threads.

Everything is measured in the screenshot the model was shown: a point is a pixel of that image,
and the browser scrolls to the screen a point was measured on before acting. The one thing read
from the page rather than the picture is which control has focus, to tell whether a click
reached its control.

The harness holds no credentials. Sign-ins are the browser side's business.

## The parts

```
                  ┌──────────── Agent ──────────────────────────────────────────┐
  Observation ───►│ observe ─ stall ─ intervene ─ memory ─ model ─ gate ─ act ─ │───► Step
  (screenshot,    │                                              │               │    (actions,
   survey, focus, │                 verify (checkpoint) ◄────────┘               │     status,
   results, notes)│                 review (zones, threads)                      │     questions,
                  │                 todo / map / report / trace                  │     report)
                  └──────────────────────────────────────────────────────────────┘
        ▲                                                                            │
        │                       Browser (app over its socket)                        │
        └──────────────────────── observe(survey) / act(actions) ◄───────────────────┘
```

### Ports (`ports.rs`)

The three traits the core is written against, each replaceable, none naming a provider or a
browser: `Model` (`complete(request) -> response`), `Decider` (`decide(decision) -> verdicts`)
and `Browser` (`observe(survey) -> Observation`, `act(actions) -> results`). The traits are
synchronous; work that must not wait runs on its own thread. `openrouter.rs` is the one driving
model client shipped; the runner adds a Decisions API client for the decision model.

### The loop (`run.rs`)

`Agent` holds the config, the models and the live sessions. `start(task, profile)` opens a
session; `step(id, observation)` answers one look with a `Step`; `drive(agent, id, browser)`
runs look, step, act, look until the run is over. The person reaches a running session through
`say` (a message), `answer` (to a question), `allow` and `forbid` (an irreversible kind), and
`resume` (another budget of steps after the limit).

One step, in order:

1. **Observe.** The screenshot must be the size the viewport says, or every point would land
   elsewhere. The reviews of the last plan's zones that ended are taken in. A click that reached
   no control is turned into guidance for the model (`focus.rs`). The results of every action sent
   since the model last looked are read: whether the click that sends the page went through, and
   whether the page refused it.
2. **Stall checks.** A screen that did not change for `max_stale` steps, or a plan refused whole
   the same way for `max_failed_steps` steps, ends the run as stuck before another model call.
   `change.rs` tells a changed page from a blinking caret without a model.
3. **Intervene.** A message from the person stops a plan that was running on its own, so the model
   changes course with the words in front of it.
4. **Continue the plan.** When the checker confirmed the screen after the last batch, the next
   batch goes out here, without the driving model.
5. **Memory and model.** The history is folded and compacted to budget (`memory.rs`); the prompt
   (`prompt.rs`) and the reply schema (`model.rs`) are built; the model answers; a reply that does
   not parse gets one repair call, a transport failure a retry with backoff, a context overflow a
   compaction and a retry (`recover.rs`).
6. **Gate.** The one place the harness may stop, change or question the plan (`gate.rs`).
7. **Act.** The first batch of the plan goes to the browser; the rest waits on its checkpoint.
8. **Verify, to-do, map, trace.** What the screen should show after the batch is kept for the
   checker; the to-do list and the map of the page are updated; the step is written to disk.

### Plans and batches (`action.rs`, `model.rs`)

The model plans a whole screen, or a whole page from a survey, at once. The plan is cut into
batches at every action with a `check` (what the screen should show once it has run), and at
most `unchecked_actions` actions run without one. Points are checked against the screenshot
before anything is sent: a point off the picture, text that types nothing, an unknown kind, are
refused with a reason the model reads next step (`Step::dropped`).

The kinds of action: `click`, `double_click`, `triple_click`, `right_click`, `hover` (each with
optional held `modifiers`), `drag` along a `path` of points (a slider, a card to another column,
a sweep over text, a stroke on a canvas), `type` into the focused control, `key` (one key or a
chord, `Enter`, `Control+a`), `scroll`, `upload` (the browser intercepts the file picker and the
harness names the task's file), `wait`, and `survey` (a request to the harness, not the
browser: the next look is the whole page).

### Verification (`verify.rs`, `review.rs`, `pointcheck.rs`)

- **Checkpoint.** After a batch, the decision model reads the screenshot against the batch's
  `check`. When it holds, the next batch goes out without the driving model; when it does not, or
  the page is still loading (a wait, then a look), the driving model looks. A fill the checker
  says went wrong aborts the rest of the plan, since it would go on to send what is wrong.
- **Zone reviews.** A plan made from a survey is carried out zone by zone (a zone is the actions
  measured on one survey screen). When a zone's last action is done the browser photographs the
  page; the decision model is asked, on a thread, for each field filled in that zone, whether it
  shows what was typed, while the next zone runs. What the reviews found wrong is told to the
  model once, with the survey that follows.
- **Point check.** Before a survey plan runs, each point that has a label is drawn, numbered, on
  its screen (`mark.rs`), and the decision model is asked whether it sits on the control the
  label belongs to. The check never overrides the model; a doubted point is acted on and the
  doubt is told to the model with its next look.

### Memory (`memory.rs`)

The prompt only grows at its end, so a provider's prompt caching pays: old screenshots are
dropped from the turns that replay them, older turns are folded into one line each, and when the
token budget is reached the oldest turns are compacted in one go, far below budget, so the
prompt grows by appending for many steps before it is compacted again.

### The page (`map.rs`, `todo.rs`)

- **Map.** Which stretches of the page, in screenshot pixels from its top, have been on screen,
  and which the model settled (looked at and said it will not need again). Settled stretches are
  not shown to the model again and are not photographed in the next survey; each keeps the
  signature of its picture, and a look that no longer matches it unsettles that stretch alone.
- **To-do list.** On every survey the model lists each question it sees, where it lies and
  whether it is answered. The reviews tick fields off or put them back, the next survey replaces
  the list, and the gates read it: a send is held while a required field is still empty.

### The gate (`gate.rs`)

In order: "done" is the page's confirmation, not the model's word (the decision model is asked;
a "done" the screen does not confirm is sent back `done_passes` times, then reported as one
that could not confirm). A stop for the person is sent back to finish everything that does not
need them first. An action that cannot be taken back (`send`, `pay`, `post`, `delete`,
`create_account`, as the model names what a click commits) goes out only as the task's
allowances say: on its own, after asking the person (the question goes out with the step and the
run goes on), or never. The fixed rules hold a send while part of the plan failed, while the
to-do list has a required field empty, and for one look after the page refused the last send.

### Intervention and the end (`run.rs`, `report.rs`, `trace.rs`)

Questions to the person are queued with the step and the run keeps going; answers arrive through
`Agent::answer` and reach the model with its next look. When the run ends, the `Step` carries a
`Report`: the outcome, what the model assumed for the person, which parts of the page no look
showed, which fields are still open, and every question with its answer. With a trace folder set
every step is written to disk in the layout acorn's `tracesum` reads: the screenshot the model
saw, the same with every action drawn on it, what it was sent and answered, tokens, cost and
time. Typed secrets are never written.

## What goes over the wire

`Observation` (from the browser): `screenshot` (a data URL), `url`, `title`, `viewport`
(size, scroll position, page size), `focus` (the focused control as the page describes it),
`notes` (what a picture cannot show: a dialog answered, a download, a window opened), `survey`
(screens from top to bottom), `zoneShots`, and `results` of the last actions (`ok`, `error`,
`detail`, `opened: file_picker`, `unreached`).

`Step` (to the browser and the person): `status` (`working`, `done`, `need_person`, `stuck`),
`message`, `actions` (flat JSON, `{"id", "kind", "x", "y", ...}` plus `scrollTo`, `pageHeight`
and `zone` for a point measured on a survey screen), `dropped`, `survey` and `surveyFocus`,
`fields`, `settled`, `questions`, `usage`, and `report` at the end.

Field names are camelCase so a browser side written against Acorn's extension protocol talks to
this harness unchanged. The app (`app/`, over its Unix socket) and the Playwright kit (`kit/`)
both speak it; `runner/` is the process that joins the harness to the app.

## Configuration (`run::Config`)

The knobs, with defaults in `Config::default()`: the most actions a reply may plan and how many
run unchecked; the stall limits; how many actions run before a check and the checkpoint
thresholds; the load wait and the review wait; how many turns keep their screenshots, how many
stay in full, and the history's token budget; how many times a "done" or a stop is sent back
and how sure the checker must be. The task's own `Persistence` and allowances come from the chat
message that started the run (`task.rs`), as numbers and lists the gates read, not as advice in
the prompt.

## Module map

| Module | Holds |
| --- | --- |
| `ports` | The `Model`, `Decider` and `Browser` traits, messages, verdicts, errors |
| `run` | `Agent`, `Config`, `Step`, the step loop, `drive` |
| `session` | One run's state: task, profile, memory, plan, counters, questions |
| `task`, `profile` | What was asked and who the run acts as |
| `observe`, `action` | What the browser reports and what it is asked to do |
| `prompt`, `model`, `recover`, `openrouter` | Talking to the driving model |
| `memory`, `change` | The history, and telling a changed page from noise |
| `verify`, `review`, `pointcheck`, `focus`, `mark` | Checking without blocking |
| `map`, `todo` | Where the run has been, and what the page still needs |
| `gate` | Done, stop, irreversible actions, the fixed rules |
| `report`, `trace` | What the person is told, and the flight recorder |

## Build history

One step, one commit; build must pass; tests stay minimal.

**A. Skeleton** — 1 crate and modules · 2 observation · 3 actions and batches · 4 traits ·
5 task · 6 session

**B. Minimal loop** — 7 step with the gate slot · 8 step limit · 9 unchanged screen ·
10 repeated failure · 11 example binary

**C. Model calls** — 12 system prompt · 13 observation text · 14 reply schema · 15 repair call ·
16 retry with backoff · 17 OpenRouter client

**D. Memory** — 18 turn history and image lifetime · 19 folding · 20 compaction ·
21 context overflow

**E. Verification** — 22 checkpoint · 23 skip the model when it holds · 24 async review ·
25 abort on a wrong fill · 26 point check · 27 missed-click guidance

**F. To-do and map** — 28 to-do list · 29 updates from reviews · 30 settled stretches ·
31 partial invalidation

**G. Intervention and report** — 32 message queue · 33 question queue · 34 end report · 35 trace

**H. Gate** — 36 verify "done" · 37 verify "stop" · 38 irreversible actions · 39 fixed rules

Since: drag along a path and held modifier keys (for the app's real input).
