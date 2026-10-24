# From a form filler to an agent: plan

The harness was built to fill forms: understand the request, look at the page, think, act,
verify, and again, one step at a time, with the driving model at every step. That loop does the
mission as asked and leaves the evidence on the screen, which is why DOM mode now passes 4 of
the 5 bench levels. It is also five times longer than the road a lookup needs. This plan keeps
what the loop does right (the mission is done, and measured) and changes how the harness
decides what to do next, so that a lookup takes a few seconds and a form still takes the care it
needs. Accuracy first, time second; cost is not a constraint.

Each stage ends with `cargo test` in `harness/` and `runner/`, `scripts/build.sh` in `app/`, and
a `bench/run.py --mode dom` run whose numbers go into `docs/harness-log.md`. A stage that lowers
the pass rate is not done.

Status: stage 0 is done (`feat/answer-in-words`, #17), stage 1 is done (`feat/intake-overlap`,
#18: the reading of the request runs while the site opens, and the intake may go to a faster
model), stage 2 is done (`feat/whole-page-map`, #19) and stage 3 is done (`feat/hybrid-pictures`:
`--mode hybrid`, a picture on a signal; on the five bench pages it scores as DOM mode does
and is the mode for pages the map cannot read). Stage 4's site notes are in progress
(`feat/site-notes`); its model tiers wait for a fast model to be named. The measurements shaped stage 2:
the `read` move needed no new move, since the map holds every node of the page and only
rendered one screen of it, so the map now lists the whole page and the model acts on any node
by number without scrolling; the person's messages needed only a way to reach the runner,
since the harness had `Agent::say`. A router apart from the driving model, the first guess
loaded in a background tab and candidates read in parallel wait for the model tiers of stage
4, where a fast model makes them pay. `docs/harness-log.md` has each stage's numbers.

## Why: where the time goes

The best DOM-mode run of L1 (the Qatar Airways baggage weight: 4 steps, judge pass) took about
80 seconds as a person waits for it. The same answer takes a rival agent 9 seconds, with no
knowledge of the site beyond what any model has.

| Part of the run | Time | What it did | What the rival does |
| --- | ---: | --- | --- |
| Before the session | 31 s | `intake::understand`: the driving model writes a summary, approaches and warnings; then the home page is opened and looked at | nothing: its first call is its first move |
| Step 1 | 6.6 s | decides, from the home page, to go to the baggage page | goes to the baggage page's address at once |
| Navigation | 12.9 s | waits for the page to parse, which its own scripts hold up | reads the page's HTML as it arrives, runs none of it |
| Step 2 | 8.2 s | sees one screen of the map, scrolls | reads the whole text at once |
| Step 3 and its check | 12.9 s | clicks the Economy tab, a decision-model check says unsure, settles | nothing: the table is in the HTML |
| Steps 4 and 5 | 7.9 s | scrolls the cut row into view, reports done | writes the answer |

The five levels together: 941 s in the bench table, plus about 30 s before each session that
the table does not count. The rival: about 135 s, with L4 (the GOV.UK checker) answered from a
guide page instead of the checker, which the bench would fail. None of the difference is one bug.
It is the shape of the loop: serial, viewport-sized, verified at every step, and driven by the
big model with a 17 KB prompt at every step.

## What stays the same

1. The harness is the brain and knows no browser. Opening tabs, loading pages in the background
   and taking pictures belong to the app and the runner.
2. The result of every action is measured, never assumed. A scroll that did not move the page is
   reported as such; a click is verified by reading the control back.
3. Inside an `act` move the checkpoints stay as they are, judged by the decision model, and a
   commit action (pay, send, post, delete) never runs without the page showing what it asked for.
4. A run ends with both an answer in words and the page that proves it on the screen.
5. The bench judges every change. Its time includes everything the person waits for.

## The design

### Moves, chosen by a router

The loop becomes: summarise the state → choose a move → run the move → update the state. The
state is the mission, the memo (a few lines the model keeps), the person's messages, and a short
summary of the current page. The router is one call of the decision model (fast, cheap), not the
driving model.

| Move | What it does | Who runs it |
| --- | --- | --- |
| `search` | writes the query, opens the results, reads the candidates | decision model, then `read` |
| `go` | opens an address the model knows or found | the browser |
| `read` | pulls the whole text of the page (every node of the map, not one screen of it, with collapsed parts marked hidden) and extracts what the mission asks; several candidates in parallel | the extraction model |
| `act` | the loop as it is today: click, type, choose, with checkpoints | the driving model |
| `ask` | puts a question to the person and goes on with the best guess until the answer comes | the router |
| `answer` | writes the answer in words, from the page, and leaves that page in view | the driving model |

The router only picks moves that can be undone. Once in `act`, the checkpoints decide when to
leave it. The person's message, when there is one, is the first input of the router and
outranks everything else.

### Readiness is per move, not per page

A page is "ready" when what the next move needs is there, not when everything has loaded. This
replaces the one settle rule for every look.

| Next move | Waits for | Does not wait for |
| --- | --- | --- |
| `read` | the document's HTML, parsed | scripts, images, fonts, layout |
| `go` by a link on the page | that link in the DOM | the rest of the page |
| `act` on a control | that control laid out, uncovered and listening (what `locate` measures) | anything off screen, images |
| a picture, or the final evidence | the visible part painted | anything off screen |

A page whose text has arrived while its images are still coming is read at once. The one
exception is `act`: a button whose script has not attached yet, or a layout still moving, makes
a click land wrong, so the control itself is measured before the click, not the page.

### No serial preamble

`intake::understand` becomes the router's first call, on the fast model: what the mission asks,
what done looks like, and the first move. While it runs, the app loads the mission's site and
the model's best-guess address in a background tab, so the first `read` or `act` finds the page
already there. A wrong guess costs a tab, not time.

### The person in the loop

The sidebar stays open while the agent works. A message from the person stops the running
batch after its current action (never in the middle of a commit action), and reaches the router
as its first input. The agent shows one line per turn: which move it chose and why. `ask` lets
the agent put a question and keep going; it never stands still waiting, as `need_person` does
today, unless the next action is one only the person may take.

### Pictures when the map is not enough (hybrid mode)

DOM mode stays the base. A screenshot joins the map only on a signal: a map too thin for the
viewport (a canvas, a map of the world, text in pictures); a check unsure twice; a click that
was covered or missed; a drag, a slider or a calendar; a captcha; and once before `done`, when
the picture is checked for the answer being in view. The picture informs; actions still go by
number. Without a signal the cost is zero.

### Models in three tiers

The router and the extraction run on a fast model (about a second a call). The driving model
stays inside `act` and writes the answer. The judge stays as it is. Routing on a smaller model
can misroute; that is why only undoable moves are routed and `act` keeps its checkpoints.

### Site notes

What a run learns about a site is written down by domain (which address holds the baggage
table; that the forum lives at `discussions.flightaware.com` and sorts by replies at
`/top?period=all`; which tab shows the Economy row) and read by the router on the next mission
there. First runs do without; second runs skip the search.

## Stages

| Stage | Work | Done when |
| --- | --- | --- |
| 0. The measure | `answer` in the reply and the trace; the bench's time counts from the runner's start; a second judge grades the answer in words against the mission | the five levels rerun with the new columns, as the baseline |
| 1. No preamble, pages ahead | `understand` folded into the first router call on the fast model; the app loads the start site and the first guess in the background; `read` waits for parsed HTML only | each mission 30 s shorter; navigation waits hidden behind model time |
| 2. Moves and the router | the move set, the router prompt, whole-page `read` with hidden parts, parallel candidates, readiness per move, the person's messages as router input, `ask` | L1 ≤ 12 s, L3 and L5 ≤ 25 s, L4's pass kept |
| 3. Hybrid pictures | the signals, the picture beside the map, the check before `done` | no run ends `page unreadable` on the bench pages; no judge fail for an answer cut off at the screen's edge |
| 4. Tiers and notes | fast model for routing and extraction; site notes written and read | L1 6–8 s; the five levels under the rival's total with L4 done honestly |

Targets, as a person waits for them, with the rival beside:

| Level | Today | Rival | After stage 2 | After stage 4 (second run) |
| --- | ---: | ---: | ---: | ---: |
| L1 | ~95 s | 9 s | 10–12 s | 6–8 s |
| L2 | ~90 s | 42 s | 20–25 s | ~12 s |
| L3 | ~430 s | 34 s | 20–25 s | ~10 s |
| L4 | ~175 s | 15 s (checker skipped) | 40–50 s | ~30 s |
| L5 | ~300 s | 22 s | 20–25 s | ~12 s |

The floor is the models: a lookup is at least three calls (route, extract, answer), and a form
step is a driving-model call plus the measured click. Beating the rival on a first run comes from
not waiting and not walking; beating it by a margin comes from the notes.

## Risks and open decisions

- Search engines block automation; the results page's map has to be checked before `search` is
  relied on. `go` to a known address comes first.
- An SPA whose bundle comes from another domain can look empty at "parsed": `read` on a page
  with almost no text waits a little longer, and the router can ask for a second look.
- Hidden parts in `read` (tabs, accordions) may hold stale or alternative content; they are
  marked, and the answer cites what was visible when the mission needs the screen to show it.
- The second judge (the answer in words) is new; its rubric comes from the mission's `judge`
  line and is tried on the five levels before it is trusted.
- Site notes are a form of memory: where they live, how they age, and that a wrong note is
  corrected by the next run, is decided in stage 4.
