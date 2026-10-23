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
in `../runner`), and shows each step in the chat. The stop button ends a run. A task without a
`url:` line starts on the page the browser shows.

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

Known limits: Chromium only paints a visible window, so the window is brought on screen when
a picture is needed; there is one tab, so a window the page opens takes this tab's place.

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
