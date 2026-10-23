# Harness log

Every change to the harness, or to the parts of the driver it depends on (waits, scrolling, the
page map, what the model is told), is written down here before its pull request: what was
observed, with the trace or the experiment that showed it; what the cause was; what was changed,
and why that rather than a patch; and what the bench said afterwards. A commit message tells
the what; this log keeps the why, so that a rule in the code can be traced to the run that
asked for it. Newest first.

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
