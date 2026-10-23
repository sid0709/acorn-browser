# Harness log

Every change to the harness, or to the parts of the driver it depends on (waits, scrolling, the
page map, what the model is told), is written down here before its pull request: what was
observed, with the trace or the experiment that showed it; what the cause was; what was changed,
and why that rather than a patch; and what the bench said afterwards. A commit message tells
the what; this log keeps the why, so that a rule in the code can be traced to the run that
asked for it. Newest first.

## 2026-10-23 — Stage 1 of the agent plan: the request read while the site opens

Branch `feat/intake-overlap`. Stage 1 of `docs/agent-plan.md` takes the serial preamble apart:
the runner read the request (one driving-model call that writes a summary, approaches and
warnings), then connected to the browser, then opened the site, then looked. The reading and
the opening need nothing of each other when the task names its site, which every bench
mission does.

**Observed.** In `bench/results/20261023-145326.md` the first step came 25–30 s after the
runner started on a good day and 215 s on a bad one (L2: the intake call alone took minutes
when the provider was slow, then the site took 71 s to parse). The intake's `done_when` for
L3 asked for "the discussion open with its reply count visible", a detail the request does
not make and the thread page does not show, and the model dithered 15 steps for it.

**Causes.**
1. `run()` in `runner/src/main.rs` did the three in sequence on one thread.
2. The intake ran on the driving model with no way to choose a faster one.
3. `intake.md` asked for a `done_when` "a checker could confirm from the last screenshot
   alone", which invites a detail the page may never show.

**Changed.**
1. When the task names its site, the reading runs on a scoped thread while the main thread
   connects and opens the site; the first look comes when the slower of the two is done. A
   request without a site is read first, since the sheet names the site.
2. `--intake-model <id>` (runner and bench) reads the request on another model; the driving
   model by default. Both are metered as model time.
3. The sheet is told to add no requirement the request does not make: for the item with the
   most of something, done is that item open; for a page to open, that page open.
4. The `understood` and `start` events carry their time from the runner's start, and the
   bench prints "understood after N s" and "first look after N s", so the preamble is seen.

**Bench after.** `bench/results/20261023-151826.md`, DOM mode: 4 of 5 on the screen, 3 of 5
answers right, 656 s of which 403 s waiting on the models (from 951 s, 3 of 5, in
`20261023-145326`). L1 pass, 4 steps, 49 s with 20 s on the models (from 275 s); L2 pass, 5
steps, 59 s (from 277 s); L4 pass, 26 steps, 247 s; L5 the capture of 1 January 2005 08:47
opened and the tsunami notice reported, which the screen judge passed and the answer judge
failed for naming no product, there being none; L3 opened a discussion with fewer replies than
the top of the sorted list and ended unconfirmed, a wrong pick by the model. The first look
came 5 s after the runner started where the request was read in parallel with the site's
opening (L5: "understood after 5 s, first look after 5 s"); the provider was also quicker
than in the afternoon run, which the model column shows.

## 2026-10-23 — Stage 0 of the agent plan: the answer in words, and the clock that counts everything

Branch `feat/answer-in-words`. The first stage of `docs/agent-plan.md` changes the measure
before the loop: a run now ends with an answer in words, the bench grades that answer beside
the screen, and the bench's clock runs from the runner's start. The baseline runs for the
stage found three more faults, fixed here with it.

**Observed.** The runs of 2026-10-23 ended with "Qatar Airways' Economy limits are visible":
the figures the person asked for were in the model's memo and on the screen, never in what
the person was told. The bench's time per mission left out the 25–30 s before the first step
(`intake::understand`, connecting, opening the site), so L1 read 63 s where a person waited
about 95. Then, in the baseline run with the new columns (`bench/results/20261023-142331.md`):
L4 ended `stuck` after six `read` actions in a row, with the GOV.UK checker's options shown as
`clickable[16] class=gem-c-label govuk-label` and no names, so the model read the labels one
by one and the stale count ended the run; L5 ended with "the browser could not run
Page.captureScreenshot" after a navigation to the archived page, which the runner treated as
fatal; and one driving-model call in L2 took 258 s (two 120 s timeouts and a retry).

**Causes.**
1. The reply had `proof` (what on the page shows the task done, for the checker) and `message`
   (a status line), and nothing meant for the person who asked.
2. The runner started its clock after the intake and the opening of the site.
3. GOV.UK's radios are `<input class="govuk-radios__input">` with `opacity: 0`, laid over a
   circle the label draws; both builders dropped any node with `opacity: 0` as hidden, and the
   label's text is `ignored` in the accessibility tree (it names the input), so neither carried
   the option's name. The fixture copy of the page had native radios and never showed it.
4. The stale count compared one look's picture with the last; `read` leaves the page as it
   was, so six reads counted as a page that stopped responding.
5. `observe` threw when `Page.captureScreenshot` failed (CEF answers a DevTools call that takes
   longer than 8 s with a failure), and the runner ends the run on a failed look.

**Changed.**
1. `answer` in the reply and the schema, on the step that ends the run, in the trace
   (`ANSWER:` on the timeline), in the runner's end event, in the sidebar, and in the bench
   table with the judge's verdict on it; a `done` without one is sent back once with a note.
   The prompts say what it is: the figures, names or conclusion read from the page.
2. The runner's clock starts before the intake; the bench says so.
3. A control that is only transparent keeps its line (both builders); a fixture page with the
   pattern (`pages/transparent.html`) and a test that the radio keeps its name.
4. A look after actions that only read the page does not count toward the stale limit.
5. A look whose picture fails is sent without one and with a note; in DOM mode the harness
   takes the map's text as the page's signature and goes on, in image mode it is refused as
   before.

**Bench after.** `bench/results/20261023-145326.md`, DOM mode, the clock from the runner's
start: L1 done, 6 steps, 275 s (203 s of it waiting on the model, one call of 93 s), the
judge's call lost to a dropped connection, the answer right; L2 pass, answer pass, 4 steps,
277 s (about 215 s before the first step: the intake call and a site that stayed "still being
parsed" for 71 s); L3 pass, answer pass, 21 steps, 204 s, the agent itself `stuck` after
dithering between the list and the thread for a reply count the thread page does not show;
L4 pass, answer pass, 17 steps, 91 s, where the transparent radios now carry their names
(from 144–306 s and one `stuck`); L5 need_person, 14 steps, 105 s: the agent opened the
Wayback capture of 31 December 2005 by asking for `web/2005/` and said so. 3 of 5 on the
screen, 3 of 5 answers right, 951 s, of which most was the provider's: the same model that
answered in 3–6 s in the morning took 20–93 s a call in the afternoon. The table now shows the
model's share apart (`model s`), so a change to the harness is judged by the rest.

**Left open.** The provider's latency: the client waits 120 s before retrying, and a call of
93 s is let be; a shorter wait with a retry is a question for the model tier of stage 4. The
"most of something" rule asked the model to leave the number in view on the item's page,
which Discourse does not show; the rule now says the number goes in the answer and the sorted
list was the proof. The intake's `done_when` can add such a detail of its own; stage 1 reworks
the intake.

## 2026-10-23 — DOM mode's first bench run: the page map moved with the scroll

Branch `fix/dom-harness`. The first `bench/run.py --mode dom` on the five levels: L1 (the Qatar
Airways baggage weight, a 3-step mission) took 60 steps and 12 minutes 30 seconds and ended
`stuck`; the run did not finish the five levels. The trace (`bench/traces/20261023-120338`) and
three Playwright experiments on the live page gave five causes, one under the other.

**Observed.** After the first scroll, every map showed an empty VIEW or the wrong screen
(`VIEW y=1740..2630` with nothing in it; the minimap listing content at y=7120 on a page 3478 px
tall). `scroll to 890` and `scroll to 1100` came back `ok` while the viewport's `scrollY` stayed
0. `read` on the paragraph that held the answer was dropped with "node [50] is plain text, not a
control" although the prompt told the model to use `read` on cut-short paragraphs. Every
navigation cost 36–38 s. The model's own time was 62% of the wall clock.

**Causes.**
1. `DOMSnapshot.captureSnapshot` reports `bounds` in the coordinates of the node's own document,
   unmoved by scrolling (shown on a local page in Playwright's Chromium 1194 and in CEF 154:
   `bounds.y` stayed 316 after a scroll of 870). `PageMap.swift` and the reference builder
   `bench/pagemap/pagemap.mjs` both added `scrollOffsetY` again, so after a scroll every box lay
   one scroll height too low. Every fixture had been captured at scroll 0, where the error is
   zero, and the only scrolling test used synthetic numbers.
2. `qatarairways.com` replaces `window.scrollTo` with a function of its own (`scrollToIsNative:
   false`); the driver's scroll called it and never measured the result, while the click path
   next to it did measure its pre-scroll.
3. `aim()` in `harness/src/model.rs` refused every target that was text, `read` included; the
   prompt promised `read` for exactly that. No test covered `read` on a text node.
4. `settled()` waited for `document.readyState === 'complete'`, for every open request, and for
   CEF's `isLoading`; the page kept loading fonts, tag managers, a captcha frame and pixels for
   over 45 s, so the wait ran to its 30 s cap and the observe wait to its 5 s cap, on every
   navigation, `#anchor` jumps included.
5. In the first rerun the model reported done with the table's last row half below the screen;
   the map listed the row (any part in view counts for text), the judge saw it cut off.

**Changed.**
1. Both builders stop adding the scroll; a child document's offset is the iframe's box less
   the child's own scroll (measured: 1000 + 500 − 200 = 1300). A fixture captured with
   `--scroll=370` (`govuk-scrolled.page.json`) and a test that the header's link stays at y=12
   and the view shows the foot. Not a patch: the cause is removed in both places and the test
   fails if it returns.
2. The driver scrolls through `scrollingElement.scrollTop` with smooth scrolling off, measures
   where the page is, and reports a page that did not move as a failed action (`unreached` when
   nothing moved, so the rest of the batch runs). The same principle the click path already had.
3. Text may be the target of `read`. A text the browser cut short ends with `…` and the map
   numbers that line; the prompt says so. Test added.
4. The wait is for the document parsed, the DOM quiet for 250 ms, and no open request of the
   page's own site that can still fill it (document, XHR, fetch, script); the load event, fonts,
   images, pixels and third parties are not waited for. After a navigation the driver first
   waits for the browser to report the new document (`Page.frameNavigated`,
   `navigatedWithinDocument`), since the old one is settled as it was. When a cap runs out the
   look carries a note saying what still held the page, so the next such case is read from the
   trace, not guessed. An experiment on the live page gave 10.8 s for the new rule against never
   within 40 s for the old.
5. A node whose box crosses the top or bottom of the view is marked `(cut off at the screen's
   bottom)`, and the prompt says to scroll such a line whole into view before done. Test added.

**Bench after.** L1 alone: 4 steps, 50 s, judge pass (from 60 steps, 12 min 30 s, stuck). The five
levels in DOM mode: 4 of 5 pass, 941 s, $0.08; L5 fails because apple.com's home page of
1 January 2005 featured a tsunami relief appeal and no product, which the agent reported. Each
navigation: 13 s (page-bound) from 36–38 s.

**Left open.** The harness's time per mission is still five times a rival agent's for lookups;
the reasons and the plan are in `docs/agent-plan.md`.
