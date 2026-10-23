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
- A look waits for the page to settle: no DOM change for 250 ms, the document loaded, and
  none of the page's requests (fetch, XHR, images; not sockets or event streams) still open.
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

## Build and run

```bash
scripts/build.sh run
```

The first run fetches CEF 154 (about 130 MB) into `ThirdParty/` and compiles its wrapper
library. To reuse an already extracted copy of the same version, set `CEF_SOURCE` to its folder.
The app lands in `build/AcornBrowser.app`, signed ad hoc, for running on this Mac only.

Needs Xcode (for `swiftc` and `clang++`), no CMake.

## Next

3. Several live tabs with frame-rate tiers.
4. Interface polish.

## Interface

The window is a tinted canvas behind rounded cards: the page in one, the agent panel in another
(⌘K). The tabs go either across the top, where the page's card carries navigation and the
address, or down a sidebar on the left, Arc's way (the layout is chosen in the ⋮ menu): window
controls and navigation, the address, pinned tabs as tiles, the agent's tab, then groups as
folders and the open tabs. ⌘S puts the sidebar away; the window's left edge brings it back over
the page while the pointer is on it. The address shows the site's name only (with copy-link and
a bookmark star under the pointer).

The command bar (`CommandBar.swift`) is how anything is opened: ⌘T for a new tab, ⌘L or a click
on the address for the tab shown. It ranks, from what the browser already knows, the address or
search, open tabs, bookmarks, history and the window's commands, and offers the words to the
agent as a task. History (⌘Y), bookmarks (⌘D) and the search engine and translate language are
in `Library.swift`, kept as JSON beside the runs; pages the agent opens while it drives are not
written to history. The menu bar lists every command; the keys are also held by
`WindowShortcuts` inside the window, so they work with the page focused. Settings (⌘,) holds
the theme, the layout, search, translation and clearing data.

The ⋮ menu follows Chromium's: New tab, New window and Incognito as tiles; zoom in place with full
screen beside it, bookmark, pin, find, translate (through Google's translating address, in the
language Settings names), print and copy link; then Bookmarks, History, Tab and Extensions,
which open inside the menu; About and Settings at the foot. The engine runs Chromium's Alloy
style, which cannot load Web Store extensions, so Extensions holds site boosts instead
(`Boosts.swift`): styles and a script of the person's own put into a site's pages when they
load, never into the agent's tab.

⌘N opens another window and ⇧⌘N an incognito one, each with tabs of its own; only the main
window has the agent. An incognito window's tabs share one in-memory profile
(`ChromiumBrowserView initWithURL:incognito:`), which goes when the last of them does; it wears
a fixed dark theme and writes no history.

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
in `Sidebar.swift`, and the pieces both layouts share (window controls, the address, the page
toolbar, the agent's ring, the shortcuts) in `WindowChrome.swift`. Where the interface is going
next is in `DESIGN.md`.
