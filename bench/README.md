# bench

How the agent is measured, modelled on Online-Mind2Web (300 tasks on 136 live sites, the
benchmark Aside, Browser Use and the model vendors report on): a task names the site it starts
on and asks for something a person would ask for there, without a sign-in; a judge model grades
the run from the screenshots and the actions, not from what the agent says at the end.

```bash
cd app && scripts/build.sh run       # the browser must be running
cd .. && bench/run.py                # the five levels, once
bench/run.py --only L4-govuk-visa --repeat 2
bench/run.py --missions bench/missions/basics --no-judge
bench/run.py --mode both              # each mission in image mode, then in DOM mode
```

## The missions

`missions/levels/` holds one mission per level, written like the benchmark's tasks:

| Level | Like the benchmark's | What it takes | Mission |
| --- | --- | --- | --- |
| 1 | easy, 2 to 3 steps | one page, one fact | the economy baggage allowance on Qatar Airways |
| 2 | easy, 4 to 5 steps | a search and a choice | a nut-free gluten-free cookie recipe on Cookpad |
| 3 | medium, 6 to 10 steps | find a section, compare, open | the most-replied community discussion on FlightAware |
| 4 | hard, 10 or more steps | a form of several questions | the GOV.UK visa check for a US healthcare worker |
| 5 | long, with an unusual control | a calendar, a date, an archived page | the Wayback Machine copy of apple.com nearest 2005 |

Each mission file is the request in plain words, then an HTML comment with `level`, `site` (where
the run starts, as the benchmark gives it) and `judge` (the key points the judge must see). The
request itself goes to the runner as a person would type it; the runner reads what "done" looks
like from it. With `--no-site` the runner is not told the site either and must find it from the
request, which is how the app's sidebar is used.

`missions/basics/` holds the earlier, simpler set (search, to-do, drawing, language switch),
with no sites or key points; run it with `--no-judge`.

## The score

For each run the table shows the mode the model saw the page in (`image`: a screenshot each
step; `dom`: the page map and no picture, see `docs/dom-mode-plan.md`), the agent's own verdict
(`done`, `need_person`, `stuck`), the judge's verdict (`pass` or `fail`, with its reason), the
steps, the time and the cost. `--mode both` runs every mission both ways, one after the other,
so the two columns of the comparison come from the same sites on the same day. The
judge is given the request, the key points, up to eight screenshots (the last one always, the
ones where a focused field had just changed its value, since a wrong pick in a dropdown and its
correction a step later look the same in an even spread, and the rest spread over the run), and
the timeline of actions; it needs `OPENROUTER_API_KEY` (from the
environment, the app's `.env`, or `kit/.env`). The judge's pass rate is the number to compare
with the benchmark's leaders; Aside reports 99.0% over all 300 tasks with GPT-5.5 (100% easy,
99.3% medium, 97.4% hard) in its own grading.

The table is written to `bench/results/<stamp>.md`; every run's trace (the screenshots the
model saw, what it was told, what it decided, the cost) is under `bench/traces/<stamp>/<mission>/`.
Results and traces are not committed: they hold the pages the run saw. A failure's trace is what
to read next: `timeline.txt` for the run at a glance, then the step where it went wrong.

The sites are live, so a mission can become impossible (a page or an offer gone); the benchmark
marks such tasks impossible rather than failed, and so should a reading of these results.

## The page map

`pagemap/pagemap.mjs` is the reference builder of the page map of DOM mode
(`harness/src/page.rs`, `app/Sources/App/PageMap.swift`): on Playwright's Chromium it asks for
the accessibility tree and the DOM snapshot and joins them the way the app does, so a change to
the rules is tried here first and the harness's fixtures (`harness/src/fixtures/*.page.json`)
are regenerated from `pagemap/pages/*.html`.

```bash
cd bench/pagemap && node pagemap.mjs pages/govuk.html https://www.gov.uk/   # → out/
```
