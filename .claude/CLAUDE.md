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

Development happens on the branch the session names, started from `feat/cef-browser-app` (or
`main` when that branch is gone), and reaches the feature branch through a pull request. No
branch holds traces, screenshots or results: `bench/traces` and `bench/results` stay ignored,
since they hold the pages a run saw and would grow the repository for nothing.

## What matters

The harness (`harness/`) is the brain and stays independent of any browser. The app (`app/`)
is the browser it drives, with the runner (`runner/`) between them. The kit (`kit/`) was the
first test bed and is kept building, not developed. Mission completion comes before interface
work: a change is judged by what `bench/run.py` says afterwards.
