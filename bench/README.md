# bench

The missions the agent is measured on: requests in plain words, as a person types them in the
sidebar, with no `url:` or `done_when:` line. The runner reads those from the request first
(the harness's intake), then does the task in the app's browser.

```bash
cd app && scripts/build.sh run       # the browser must be running
cd .. && bench/run.py                # every mission once
bench/run.py --only excalidraw-flowchart jspaint-circle --repeat 3
```

Each run prints what the runner understood (the site and what "done" looks like), its steps,
and how it ended; the table at the end, with the number done out of all, is written to
`bench/results/<stamp>.md`. Every run's trace (the screenshots the model saw, what it was told,
what it decided, the cost) is under `bench/traces/<stamp>/<mission>/`. Results and traces are
not committed: they hold the pages the run saw.

The missions cover what an agent browser must manage without a sign-in: finding a site from the
request alone, searching, reading and reporting a fact, filling and ticking things in a web app,
drawing on a canvas with the mouse, and switching a page's language. Add a mission as a `.md`
file with the request in it; keep it to what a screenshot can confirm at the end, since that is
what the harness checks a "done" against.

A failure's trace is what to read next: `timeline.txt` for the run at a glance, then the step
where it went wrong, with its screenshot and what the model answered.
