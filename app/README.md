# app

A Mac browser on Chromium (CEF) with an agent sidebar. It is separate from `harness` and `kit`:
the harness is the brain, and this app is meant to become the browser it drives.

## Stage 1

A window with one Chromium page, a toolbar, and an empty chat sidebar. The sidebar takes input
but no agent is connected yet.

## Stage 2: the browser can be driven

The app listens on a Unix socket (`~/Library/Application Support/com.acorn.browser/agent.sock`,
mode 0600, or `ACORN_AGENT_SOCKET`) and speaks the same one-JSON-object-per-line protocol as
`kit/browser/browser.mjs`: `open`, `observe` (with `survey`), `act`, `close`, with the harness's
own observation and action shapes. Everything goes through Chromium's DevTools protocol, so
the harness cannot tell this browser from the Playwright one.

- Screenshots are JPEGs at one pixel to a CSS pixel, so a point in the picture is a point to click.
- Actions: click, double/triple/right click (with modifier keys held), hover, drag along a path,
  type, key chords (`Enter`, `Meta+a`), scroll, wait, upload (the file picker is intercepted and
  the task's file handed to the page; a plain click that opens the picker reports
  `opened: file_picker`).
- **Typing is measured, not predicted.** Where keys go is not guessed from the page's idea of
  focus (a canvas, a game, an editor of its own, a frame of another site all take keys without
  it): the page counts the keys it gets, the keys it handled, and the text that went into a
  control, and the screen is glimpsed before and after. The first character is a probe: when it
  did nothing at all, the rest is not typed and the action reports it reached nothing. A
  survey point is refused only when the page shrank or could not be scrolled to where the
  point was measured; a page that grew below (a list that loaded more) is acted on.
- **The agent has a pointer and keyboard of its own.** Its events are built as the system
  builds them from the hardware (`NSEvent`) and handed to Chromium's view the way the window
  hands them over, not injected through DevTools: a drag is a button held through a path of
  moves a few pixels apart, a double click is two clicks with the system's click count, keys are
  the keys of the keyboard with their modifiers held round them, and `event.buttons` says the
  button is down. A page cannot tell them from a person's: a drawing tool gets a stroke. The
  person's own mouse and keyboard are left alone, so the computer stays usable during a run; the
  agent's pointer is drawn on the page as an orange arrow, beside the person's. A page's own
  drag and drop (a card to another column) is carried through the browser the way the system
  would carry it. Characters a keyboard cannot type (Chinese, say) are committed the way an
  input method commits them, and the page's input context uses a Latin layout while the agent
  types, whatever the person's keyboard is set to. Chords the system owns (`Meta+q`,
  `Meta+Tab`, ...) are refused.
- A look waits for the page to settle: its document parsed, no DOM change for 250 ms, and none
  of the requests that can still fill it (the page's own document, XHR, fetch and scripts, from
  the page's own site) still open. The load event is not waited for, nor are fonts, pictures,
  pixels, sockets, or anything a third party serves (tag managers, chat widgets, captchas): a
  page may go on loading those for a minute after a person could read it. After a navigation
  the look first waits for the browser to report the new document, since the old one is
  settled as it was.
- A scroll to a height is made through the scrolling element's own position (a page may put a
  function of its own in `window.scrollTo`) and measured afterwards: a page that did not move
  is reported as such, never assumed scrolled.
- While the harness is connected, the page's dialogs are answered (alert and beforeunload
  accepted, confirm and prompt dismissed), downloads are noted, and a window the page tries to
  open is opened in this tab; all of it is reported in `notes`. When the connection ends the
  page is given back to the person.
- If the window is hidden when a picture is needed, it is brought forward and the picture
  taken again.

```bash
scripts/build.sh run        # start the app
Tests/agent_smoke.py        # drives it over the socket and checks 19 things
```

## Stage 3 (this): type a task, and it is done in the page

Type a task in the sidebar (or paste a task file with `url:`, `done_when:`, `steps:` lines, like
the ones in `kit/tasks`). The app writes it to a task file, starts `acorn-runner` (the harness,
in `../runner`), and shows each step in the chat. The stop button ends a run. A request in
plain words, with no `url:` or `done_when:` line, is read by the model first: the site it means,
what the screen will show when it is done, what it permits (send, pay, post, delete, sign up),
and how hard to push; the chat shows what was understood before the first step. A request about
"this page" starts where the browser is. The model can also go to an address on its own
(`navigate`) when the task needs another site. The button in the sidebar's header picks the
model that drives the page (`gpt-6-luna` by default) from every model OpenRouter lists, with a
search field. The chosen model's inputs and outputs, context, reasoning efforts and every price
are shown beneath the list, and a model that cannot read the screenshots is flagged. The list
comes from OpenRouter's public `/api/v1/models` (no key needed) and is kept in
`openrouter-models.json` beside the runs for offline use; the choice is kept between launches. The checks between batches use the runner's own decision
model, which the sidebar does not change.

**One-time setup: the model key.** The runner reads `OPENROUTER_API_KEY` from
`~/Library/Application Support/com.acorn.browser/.env`, which is outside the repo:

```bash
mkdir -p ~/Library/Application\ Support/com.acorn.browser
cp ../kit/.env ~/Library/Application\ Support/com.acorn.browser/.env
chmod 600 ~/Library/Application\ Support/com.acorn.browser/.env
```

Each run keeps a folder under `~/Library/Application Support/com.acorn.browser/runs/`: the task,
`events.jsonl` (what the agent said and did), and the harness's trace (every screenshot).

`AcornBrowser --run-task <file>` submits a task file at launch, for trying it without typing.

The runner greets the app first (`hello`, with the protocol version each speaks) and refuses to
run against an app built before this runner: an older app would refuse a kind of action mid-run
and look like a page that does not work. Rebuild both with `scripts/build.sh`.

A native dropdown (`<select>`) opens the system's own menu, which waits for the person's mouse:
a click on one gives it the focus instead, and the model picks from the options the focus
information lists with a `choose` action, which sets the option by its text and tells the page
(typing into the dropdown would jump to the first option that starts with the letters, and
"United States" landed on "United Arab Emirates" that way). A control inside a frame of another site (a payment form) cannot be
described; typing goes to it all the same.

Known limits: Chromium only paints a visible window, so the window is brought on screen when
a picture is needed; there is one tab, so a window the page opens takes this tab's place.

The missions in `../bench` measure the whole: `bench/run.py` runs each plain request against
the running app and keeps the score.

```text
Sources/App/        SwiftUI: window, toolbar, chat sidebar, one tab's state
Sources/Chromium/   Objective-C++ bridge to CEF (engine start-up, the browser view)
Helper/             the helper executable Chromium starts for its other processes
Config/             Info.plist and entitlements
scripts/            setup-cef.sh, build.sh
```

## DOM mode and the page map

Every look also carries the page as this browser knows it (`PageMap.swift`): the accessibility
tree joined with the DOM snapshot through DevTools, as a list of nodes with their computed name,
live state and box in page coordinates, child frames fetched apart and hung under their frame.
Nothing is written to the page. The harness writes it to the trace (`NNN.page.txt`).

An action that names a node of the map (`target`) is placed by the browser, not by the point
the harness sent: the node is found again by role and name if the map was renumbered since,
scrolled into view, measured now, and the point must hit it (a node under a banner or a dialog
is refused, saying what covers it); the click is then the same human-paced click as any other.
The control's state is read before and after and the result says what changed. `scroll` with
`to` goes straight to a height of the page; `read` answers with a node's whole text.

The switch beside the model menu picks how the next run sees the page: **Image** (a screenshot
each step, the default) or **DOM** (the map and no picture, `acorn-runner --mode dom`). It is
locked while a run is on. The plan and its stages are in `docs/dom-mode-plan.md`.

## Build and run

```bash
scripts/build.sh run
```

The first run fetches CEF 154 (about 130 MB) into `ThirdParty/` and compiles its wrapper
library. To reuse an already extracted copy of the same version, set `CEF_SOURCE` to its folder.
The app lands in `build/AcornBrowser.app`, signed ad hoc, for running on this Mac only.

Needs Xcode (for `swiftc` and `clang++`), no CMake.

### When the window stalls

A watcher thread notes every moment the main thread does not answer for over a quarter of a
second, and what held it, in `~/Library/Application Support/com.acorn.browser/perf.log`. Lines
look like this (numbers made up):

```
… new tab, 5 open
… create browser took 180 ms (5 browsers)
… main thread stuck 1340 ms, 1290 ms of it on the CPU (5 browsers, 3 pump runs): chromium pump 1180 ms, AppKit/SwiftUI 160 ms
  main thread's stack, 2 of 2 samples:
    #0  …
```

The shares are sampled every 10 ms across the sections the code marks (`ChromiumPerf.enter`
and `leave`, `chromium::PerfScope` in Objective-C++); `AppKit/SwiftUI` is time in none of
them. Few pump runs over a long stall mean single long Chromium tasks; many mean a backlog.
CPU time well short of the stall means the main thread was waiting, not working. From 400 ms
into a stall the main thread's call stack is taken every half second; the distinct stacks
follow the line, each frame with its library, symbol and offset in the image.
`tail -f` the file, or `log stream --predicate 'eventMessage CONTAINS "acorn-perf"'`.
`defaults write com.acorn.browser perfWatch -bool NO` turns the watcher off.

## Next

3. Several live tabs with frame-rate tiers.
4. Interface polish.

## Interface

The window is a tinted canvas behind rounded cards: the page in one, the agent panel in another
(⌘K). The tabs go either across the top, where the page's card carries navigation and the
address, or down a sidebar on the left, Arc's way (the layout is chosen in the ⋮ menu): pinned
tabs as tiles, the agent's tab, then groups as folders and the open tabs. In that layout one row
runs along the window's top whether the sidebar shows or not (`SidebarTopBar`): the window's
buttons, the sidebar toggle and back, forward and reload on the left, and the page's title and
site centered over the page, which a click or ⌘L opens for editing in place, with suggestions.
⌘S puts the sidebar away; the window's left edge brings it out below that row while the pointer
is near. The window's close, minimize and zoom buttons are the system's own, moved by
`WindowConfigurator` into the top row and kept there through resizing and full screen.

The command bar (`CommandBar.swift`) is how anything is opened: ⌘T for a new tab, ⌘L or a click
on the address for the tab shown. It ranks, from what the browser already knows, the address or
search, open tabs, bookmarks, history and the window's commands, and offers the words to the
agent as a task. History (⌘Y), bookmarks (⌘D) and the search engine and translate language are
in `Library.swift`, kept as JSON beside the runs; pages the agent opens while it drives are not
written to history. The menu bar lists every command; the keys are also held by
`WindowShortcuts` inside the window, so they work with the page focused.

Settings and Extensions are pages in a tab, as in Chrome: `acorn://settings` and
`acorn://extensions` (`AcornPages.swift`). Acorn's tabs are Alloy views on macOS, which have no
`chrome://settings` or `chrome://extensions`, so those two addresses open Acorn's pages too.
Chromium cannot load the `acorn` scheme: the tab loads an empty page marked with the page's name
(`about:blank#acorn-settings/privacy`) and the app draws the page over it, as it does the start
page, so back, forward, reload and duplicate work and the agent can still take the tab. ⌘, and
the ⋮ menu open Settings (`SettingsPage.swift`): a sidebar of sections, each at its own address
(`acorn://settings/privacy`), and a search over all of them. It holds the agent's model and key,
the theme, tab layout and font sizes, the search engine (one's own too, with `%s`), the start
page, clearing browsing data by time range, the choices kept per site, downloads, translation,
the engine's state, a reset and the versions. A site's request (camera, location...) is
remembered when "Remember for this site" stays ticked, and Site Settings lists and changes
those choices. Downloads go to the folder Settings names (`downloadFolder`, read by the bridge)
and may ask where to save each file, except while the harness is connected, so a run is never
stopped by a save panel. The person's font sizes reach new tabs of theirs, never the agent's.

The ⋮ menu follows Chromium's: New tab, New window and Incognito as tiles; zoom in place with full
screen beside it, bookmark, pin, find, translate, print and copy link; then Bookmarks, History, Tab and Extensions,
which open inside the menu; About and Settings at the foot. The person's tabs are Chrome-style
views (`usesChromeStyle`), which run Chrome's extension system; the agent's tab stays an Alloy
view, the plain page `AgentDriver` was built for, and runs none (Settings can turn Chrome style
off for new tabs). Extensions come from the Chrome Web Store (`Extensions.swift`): its own Add
button where it can install into this browser, and otherwise "Add to Acorn" in the address of an
extension's Store page, which fetches the Store's package, unpacks it beside the runs keeping
the Store's id, and loads it at the next launch (`ChromiumEngine.extensionDirectories`, as
`--load-extension`). The puzzle piece beside the address lists them and opens their popups;
`acorn://extensions` (`ExtensionsManager.swift`) manages them as Chrome's page does: a card each
with its switch, a search, and a page of details (what it may reach, its id and folder). It
also holds site boosts (`Boosts.swift`): styles and a script of the person's own put into a
site's pages when they load, never into the agent's tab.

Tabs are dragged (`TabDrag.swift`): onto either end of another tab to move there, taking its
group and pin; onto its middle to make a group of the two (the new folder's name opens for
typing); onto a group's label or folder to join it; onto the open space below the sidebar's tabs
to leave a group or a pin; among the pinned tiles to pin. The agent's tab neither moves nor
takes a drop.

⌘\ (or the ⋮ menu, or a tab dropped on a page's right edge) puts two tabs side by side
(`SplitView.swift`), each with its own toolbar and a handle between them; the pane clicked last
is the active tab. When the harness takes the agent's tab while the person is on another, the
agent's page docks beside theirs (watch mode), so Chromium keeps painting it and they can watch
it work; it keeps the width it had before there was a split as far as the window allows, and
undocks when the harness lets go.

Translation works as Chrome's does, in place (`Translator.swift`). When a load ends in one of
the person's tabs, the page's language is told from its text (`NLLanguageRecognizer`); if it is
not the one Settings names, the address offers a translation. Translating hands the page's text
nodes out in batches, the visible ones first, has them translated by Google's translator (the
app makes the request, so no site's security policy stops it), and swaps each node's text where
it stands, keeping the original for Show Original. Text that appears later is translated as it
comes (the page calls back through a DevTools binding). Always and never are kept per language.
The agent's tab is never translated.

⌘N opens another window and ⇧⌘N an incognito one, each with tabs of its own; only the main
window has the agent. An incognito window's tabs share one in-memory profile
(`ChromiumBrowserView initWithURL:incognito:`), which goes when the last of them does; it wears
a fixed dark theme and writes no history.

The app opens on a start page (`StartPage.swift`) instead of a website: a greeting, a search
that suggests what the command bar does, a dial of the sites visited most (with their icons
cached from earlier visits, so it needs no network and looks the same offline), and a way to
ask the agent. It is drawn by the app over an empty page (`about:blank`), which stays mounted
underneath, so the harness can navigate the tab at any moment; it goes as soon as the tab goes
anywhere. The ⋮ menu and the command bar bring it back; ⌘T still opens the command bar.

The first tab is the agent's: it is marked with a sparkle, cannot be closed, and is the page
`AgentDriver` and the harness work in. While the harness has it (from its first request to the
end of the connection) its card wears a slowly turning ring in the agent's colors, and, if it is
the tab shown, the sidebar steps aside so the page the agent sees is no narrower than it was
before there was a sidebar.

The tint is the person's: the palette button opens the theme picker (presets, a pad where one
to three colors are set, intensity, grain, light or dark). No view draws with a fixed color;
each reads a `Palette` derived from the theme (`ThemeStore.swift`), whose text and accent are
picked to stay readable in either appearance. Spacing, radii, type and the shared button styles
are in `Theme.swift`, tab state in `TabStore.swift`, the strip in `TabStrip.swift`, the sidebar
in `Sidebar.swift`, and the pieces both layouts share (the window's buttons, the address, the page
toolbar, the agent's ring, the shortcuts) in `WindowChrome.swift`. Where the interface is going
next is in `DESIGN.md`.
