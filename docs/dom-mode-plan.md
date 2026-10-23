# DOM mode: plan

Acorn Browser's agent has one way of seeing a page today: a screenshot (image mode). This plan
adds a second, DOM mode, in which the model never sees a picture. It reads a *page map* built
from what the browser already knows about the page, acts on elements by number, and verifies by
reading the page back. The two modes are switched in the agent sidebar, so each can be measured
on its own with `bench/run.py`.

The plan is in five stages. Each stage ends with `cargo build` (no warnings), `cargo test`, and a
`bench/run.py` run; a stage that lowers the pass rate is not done.

Status: all five stages are in the code: the map, acting by number, the DOM-mode prompt and
gate, the switch and `bench/run.py --mode both`, and the folding of repeated blocks with the
byte budget. The maps were checked on GOV.UK from the app. Still to do, on a Mac with the
network: the DOM-mode runs of the five missions and the comparison table (stage 4's last
item), and the stage 5 measurements on live shopping pages with `bench/pagemap/compare.mjs`,
which set the budget and the folding thresholds for good. Sending only the changed lines from
the second look on is left out for now: a look's map is a few kilobytes and its numbers change
between looks, so the whole map goes each time until the measurements say otherwise. The
isolated-world alternative to the snapshot is not needed so far: a page of 96 cards maps in
about 150 ms on Playwright's Chromium.

## Why

A run of the L4 mission (the GOV.UK visa check, 7–8 short pages) takes 5–6 minutes in image mode.
Each page costs a survey (scroll and photograph the whole page), a driving-model call that reads
several images, a point check, a checkpoint per action and a wait for the zone reviews. Most of
that time is spent guessing, from pixels, things the browser already knows exactly: what a control
is called, whether it is checked, whether it is visible, and where it is.

Three sources were studied for the page map; none is enough alone.

| Source | Strong at | Weak at |
| --- | --- | --- |
| Chromium accessibility tree (`Accessibility.getFullAXTree`) | the computed name of a control (label, `alt`, `aria`), its live state (checked, selected, expanded, disabled, required), hidden things left out, cross-origin frames | `div` buttons with no role (dropped as "generic"), no positions, no developer hints |
| Chromium DOM snapshot (`DOMSnapshot.captureSnapshot`) | positions, paint order, computed style (`display`, `visibility`, `opacity`, `cursor`), attributes, frames | large, no names, no meaning |
| Oak's serializer (`Oak/extension/src/content/dom-serializer.ts`, `Oak/shared/tree-export.ts`) | what to keep and how to write it: flatten empty wrappers, whitelist attributes, one line per node, number the nodes, act by number and relocate by label and role when a number goes stale | reads `checked` and `selected` from the HTML attribute, not the live state (a value of `""` is dropped, so even an initially checked box disappears); keeps hidden elements; skips cross-origin iframes; stamps `data-oak-id` on the page; drops `alt` and `title`, so icon-only buttons have no name |

DOM mode takes the facts from Chromium and the editing rules from Oak, and keeps the harness's
own way of acting (a human-paced click at a point the browser measured).

## Design in ten lines

1. **Map material.** Accessibility tree + DOM snapshot, joined on `backendNodeId`.
2. **Selection.** Keep what can be pressed, filled, read: controls, headings, labels, text, groups,
   repeated blocks. Drop hidden and zero-size nodes, empty wrappers and images (keep `alt` as a
   name). Elements with `cursor: pointer` and no role are kept as `clickable`. Class tokens are
   added only to a clickable element with no name, or to tell apart two elements with the same role
   and name in one region.
3. **In view: detail.** One line per node: `radio[6] "Work, academic visit or business" checked @412,318 220x24`.
4. **Out of view: minimap.** One line per region: `y=1600..9800 results 3-12: 80 products`.
5. **Budget.** About 24 KB a look. Over budget, keep by priority: controls in view, headings and
   labels, text in view, minimap. From the second look on, send only the lines that changed. Long
   text is fetched on request with `read [id]`.
6. **Coordinates belong to the browser.** The model names a number. Before acting, the app measures
   the element again (`DOM.getBoxModel`), scrolls it into view, checks that the point hits that
   element (`DOM.getNodeForLocation`), then clicks as a person would. One coordinate system: CSS
   pixels from the top of the document; the viewport offset is subtracted only at the click.
7. **Verification by reading back.** A machine-readable check (`checked`, `value=`, `url~=`,
   `exists "text"`, `focused`) is judged from the DOM in milliseconds, with no model. A check in
   words goes to the decision model with the map text, never a picture.
8. **Freshness.** The map is rebuilt at every look. The element acted on is read again just before
   and just after the action.
9. **The switch.** Sidebar `[Image | DOM]` → runner `--mode dom` → `Task.mode` in the harness →
   `bench/run.py --mode dom`. In DOM mode the model gets no image and there is no fallback to one: a
   page the map cannot read ends the run as stuck, so the benchmark shows where DOM mode fails.
10. **Screenshots stay.** They are still taken every look, for the trace and the bench judge; they
    are not sent to the model.

## Stage 1: build the page map, record it only

**Goal.** See real page maps from real runs without changing how the agent behaves.

**Work.**
- `app/Sources/App/PageMap.swift`: call `Accessibility.getFullAXTree` and
  `DOMSnapshot.captureSnapshot` (computed styles `display`, `visibility`, `opacity`, `cursor`;
  DOM rects) together, through the existing DevTools call (`AgentDriver.swift`, `call(_:_:)`).
  Join on `backendNodeId`. Apply the selection rules above. Split into *in view* and *minimap*.
  Collect every frame: same-origin frames come with the snapshot; cross-origin frames need
  `Target.setAutoAttach`, a call per frame, the frame's box added to its children's boxes, and a
  frame tag on every number.
- `harness/src/page.rs`: the `PageMap` types (nodes, boxes, regions, frames), the text rendering,
  the budget and priority order, and the diff between two maps. Browser-independent: any browser
  that can produce the same shape can drive it.
- `harness/src/observe.rs`: `Observation.page: Option<PageMap>`.
- `harness/src/trace.rs`: the map text in every step's record. The screenshot stays.

**Done when.** Image mode runs exactly as before, and each step's trace folder holds the map
text. Review the maps from the five bench missions by hand: names, states, visibility, frames.

**Risks.** Whether CEF lets DevTools attach to a cross-origin frame has to be tried; if it does
not, disable site isolation for the agent's browser or walk frames through CEF's frame API.

## Stage 2: act by number, verify by reading back

**Goal.** A click by number lands where a click by coordinate would, and a check costs no model
call.

**Work.**
- `harness/src/action.rs`, `model.rs`: every pointed action takes `target: <number>` as an
  alternative to `x, y`; `scroll` takes `to: <y>` or `target`; new `read` action for long text.
  Point checks (`check_actions`) accept a target instead of a point.
- `app/Sources/App/AgentDriver.swift`: resolve a number to its `backendNodeId` (with frame),
  measure the box again, `DOM.scrollIntoViewIfNeeded`, hit-test the centre, then the existing
  human-paced click path. A stale number is relocated by role + name (+ group), as Oak's
  `relocateElementByPlan` does; a miss is reported as a failed action, never guessed.
- Machine-readable checks judged from the DOM: `checked`, `value=`, `url~=`, `exists "…"`,
  `focused`. The element is read before and after the action, and the result carries both.
- `harness/src/verify.rs`: a batch whose check is machine-readable continues without the decision
  model.

**Done when.** On the bench pages, numbered clicks hit the same elements as the model's coordinate
clicks did in the image-mode traces, and typed values are confirmed by read-back alone.

## Stage 3: the DOM-mode prompt and gate

**Goal.** A whole mission runs with no image sent to the model.

**Work.**
- `harness/src/prompts/system-dom.md`: the DOM-mode system prompt (map format, numbers, checks,
  `read`, minimap and `scroll to`). The image prompt is untouched.
- `harness/src/model.rs`: the DOM-mode reply schema.
- `harness/src/task.rs`, `run.rs`: `Task.mode`; in DOM mode the observation text is the map (full
  on the first look of a page, changed lines after), `images` is empty, surveys and point checks
  are off.
- `harness/src/gate.rs`: the done proof, the refused send, the human check and the person-only
  fields are asked of the decision model with the map text instead of a picture.
- No fallback: a map with too little in it for the viewport (a canvas, a map, an image of text)
  ends the run as stuck with the reason `page unreadable in DOM mode`.

**Done when.** `cargo test` passes with tests for both modes, and at least one bench mission
completes in DOM mode end to end.

## Stage 4: the switch and the benchmark

**Goal.** Measure DOM mode against image mode on the same missions.

**Work.**
- `runner/src/main.rs`: `--mode image|dom` (default `image`).
- `app/Sources/App/ChatSidebar.swift`: an `[Image | DOM]` segmented control beside the model
  menu, locked while a run is on; `AgentRunner.swift` passes `--mode`.
- Trace: `mode` on the session and every step.
- `bench/run.py --mode dom`: passes the flag through; the results table gains a `mode` column.
- Run the five levels in both modes, more than once, and write the comparison into
  `bench/README.md`: pass rate, steps, seconds, cost, tokens.

**Done when.** The comparison table exists and is reproducible with one command per mode.

## Stage 5: tune the minimap and the budget

**Goal.** Maps stay small and fast on heavy pages without losing what a task needs.

**Work.**
- Measure on pages with many cards (shopping search results, long listings) once the environment
  can reach them: raw HTML, snapshot, accessibility tree and map sizes; extraction time; controls
  missed; hidden nodes included; icon-only controls without a name; visible prices kept. The
  measuring script written for this lives in the session scratchpad and can move into `bench/`.
- From the numbers: the minimap's region rules, the folding of repeated blocks (first few in
  full, the rest as one line each), the priority order and the 24 KB budget, the changed-lines diff.
- If `DOMSnapshot.captureSnapshot` is too slow on large pages, compute boxes and visibility for
  the kept nodes only, in an isolated world (no script reaches the page, nothing is written to it).

**Done when.** The average map size and extraction time on the bench and shopping pages are within
the targets set from the measurements, and the DOM-mode pass rate did not drop.

## Open decisions for the owner

- The harness README says the harness is "pure image based". DOM mode makes it two modes; the
  README and the architecture notes are updated in stage 3.
- DOM mode has no image fallback by design, so that the benchmark is honest about its gaps. A mixed
  mode (map + screenshot) can be measured later as a third mode.
- Network access from the cloud environment is needed for the stage 5 measurements on shopping
  sites.
