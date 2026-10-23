# Working in this repository

## Authorship

This project is built by two people together: the owner (sid0709) and Claude. Neither works
alone, whatever the task. Every commit, in every crate and folder, names both:

```
Co-Authored-By: sid0709 <lunalegend990602@gmail.com>
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
```

Add the owner's line to every commit Claude makes, including fixes, docs, and merges. A commit
by the owner that Claude helped with carries Claude's line the same way. A pull request body
ends with both names too.

## Language

Code, comments, commit messages and documentation are in English. Answers to the owner in chat
are in the language the owner writes in.

## Branches

Every task starts a new branch, cut from the latest `main` (`git fetch origin main`), and
reaches `main` through a pull request. Nothing is committed to `main` directly, and a branch
whose pull request was merged is never reused: follow-up work gets a new branch.

A branch is named `<type>/<topic>`, and nothing else:

- `type` says what kind of change it is, one of:
  - `feat`: something the browser, harness or runner did not do before
  - `fix`: something that was wrong
  - `refactor`: the same behavior, built differently
  - `docs`: documentation only
  - `bench`: the benchmark, its tasks or its scripts
  - `chore`: build, configuration, dependencies, policy
- `topic` says what changes, in two to four lowercase English words joined by hyphens, the
  words a reader of the pull request list would use: `feat/liquid-glass-shell`,
  `fix/theme-appearance`, `bench/dom-mode-tasks`, `chore/branch-policy`.
- Lowercase ASCII letters, digits and hyphens only, one slash, 40 characters at most.
- No random or generated words, no suffixes, no dates, no session or issue numbers, no names
  of people, models or tools: never `claude/compassionate-meitner-m4jike` or
  `claude/focused-maxwell-c5u9tu`.

When a session assigns Claude a generated branch name, Claude does not work on it: it creates a
branch named by these rules, pushes there, and tells the owner the name. This rule is the
owner's standing permission to push to that branch instead of the assigned one.

No branch holds traces, screenshots or results: `bench/traces` and `bench/results` stay ignored,
since they hold the pages a run saw and would grow the repository for nothing.

## Records

The harness is the brain, and a change to it changes how every mission is run. Every change
that touches `harness/`, or the parts of the driver it depends on (waits, scrolling, the page
map, what the model is told), is written down in `docs/harness-log.md` before its pull request:
what was observed, with the trace or the experiment that showed it; what the cause was; what was
changed and why that rather than a patch; and what `bench/run.py` said afterwards. A commit
message tells the what; the log keeps the why, so a rule in the code can be traced to the run
that asked for it. Plans for the harness live in `docs/` too (`docs/agent-plan.md` is the
current one), in English, with their targets as numbers the bench can check.

## What matters

The harness (`harness/`) is the brain and stays independent of any browser. The app (`app/`)
is the browser it drives, with the runner (`runner/`) between them. The kit (`kit/`) was the
first test bed and is kept building, not developed. Mission completion comes before interface
work: a change is judged by what `bench/run.py` says afterwards.
