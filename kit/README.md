# harness-kit

A small kit that runs the [harness](../harness) against a real browser. The harness is the
brain and stays on its own; this folder is the hands and eyes: a Playwright page driven from a
Node process, an OpenRouter model to drive and to check, and a few tasks as Markdown files.

```text
kit/
  src/main.rs        the runner: reads a task file, starts the browser, loops look -> step -> act
  src/browser.rs     the harness's Browser trait over a Node process (JSON lines on stdin/stdout)
  src/decide.rs      the harness's Decider trait over OpenRouter's chat API
  src/taskfile.rs    a task as a Markdown file: a few key: value lines, then the goal
  browser/           the Node side: one Playwright page that looks and does
  tasks/*.md         five tasks to try
  pages/form.html    a local form the first task fills, so the kit runs with no internet
  profile.md         who the run acts as (no passwords: the harness holds none)
  traces/            one folder per run, written while it goes (not committed)
```

## Set up

- Rust (stable) and Node 18 or newer.
- `cd kit/browser && npm install` (Playwright, and its Chromium unless you already have one;
  `npx playwright install chromium` fetches it when npm did not).
- An OpenRouter key in `OPENROUTER_API_KEY`.

## Run a task

```bash
cd kit
OPENROUTER_API_KEY=sk-or-... cargo run -- tasks/local-form.md            # works offline
OPENROUTER_API_KEY=sk-or-... cargo run -- tasks/todomvc.md --headed      # watch the window
cargo run -- --help
```

The terminal shows each step: what the model said, the actions sent, what the harness dropped,
the to-do list it read, and the questions it asked. The run ends with the report: what the model
assumed, what was left, what was asked. The exit code is 0 when the task is done, 1 when the run
stopped for you or got stuck, 2 when something failed.

Every run writes a trace folder under `traces/<run id>/`: the screenshot the model saw, the same
with its actions drawn on it, what it was told and answered, every model call with its cost, and
`timeline.txt`. The files are those Acorn's `tracesum` reads, so `go run ./cmd/tracesum` in
`Acorn/acorn-agent` sums a run of the kit too.

Options: `--model <id>` and `--decider <id>` pick the driving and the decision model (the
decision model answers yes/no questions about screenshots: a cheap, quick one does; `--decider
none` turns the checks off and the run plans six actions at a time), `--reasoning low|medium|high`,
`--profile <file>`, `--trace <dir>`, `--viewport 1280x720`.

## A task file

```markdown
---
url: https://example.test/form        (or a path relative to the file, for a local page)
done_when: the page says the order was received
allow: send, pay=never                (send, pay, post, delete, create_account; =ask or =never)
survey: yes                           (plan a long page from screenshots of all of it)
steps: 30
persistence: relentless               (stop only for what a person alone can do)
resource: cv = files/cv.pdf | My résumé
---
The goal, in your own words.
```

A kind of action not listed under `allow` is asked about: the run holds the click, prints the
question, and goes on with the rest. The kit does not read an answer from the terminal; the
model carries on with its own assumption, and the run ends ready for you when the held click is
all that is left. Set `allow: send` for a task you want sent.

## What the browser side does

- A look: a JPEG of the viewport, the page's address and title, the scroll position and the
  page's size, and the focused control as the page names it (its label, kind, value and options;
  never a password's value). With a survey: the whole page as screens from the top down, each at
  its own scroll position, leaving out the stretches the harness settled and adding one centred
  on each field whose fill did not verify.
- Actions: clicks at a point, typing into the focused control (refused as "unreached" when
  nothing has focus), key chords as Playwright names them (`Control+a`, `Enter`), the wheel, an
  upload answering the file picker with a file from the task, and waits. A failure stops the
  batch and the rest is reported as not run. When a zone of a plan (the actions measured on one
  survey screen) is done, a photo is taken for the harness to review on the side.
- Things the picture cannot show come as notes: a dialog that was closed, a file that
  downloaded, a tab the page opened (which becomes the one shown).

Protocol, for another browser side: one JSON object per line. Requests `{"id", "cmd": "open",
"url"}`, `{"cmd": "observe", "survey", "focus": [y], "settled": map}`, `{"cmd": "act",
"actions": [...]}`, `{"cmd": "close"}`; replies `{"id", "ok": true, "observation" | "results"}`
or `{"ok": false, "error"}`. The shapes are the harness's own (`harness/src/observe.rs`,
`action.rs`), as serde writes them.

## Is Playwright needed?

No: the harness sees only its `Browser` trait, and anything that can take a screenshot and
click at a point will do (a Chrome DevTools client in Rust, an extension, a phone). Playwright is
the quickest way to a real browser with dependable input and screenshots, and the one most people
already have; that is all this kit uses it for.

## Test

`cargo test` runs the browser side against `pages/form.html` with no model: it opens the page,
clicks and types where the fields are, and checks the page says the order was sent. It is skipped
when Node with Playwright is not installed.
