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
- Actions: click, double/triple/right click, hover, type, key chords (`Enter`, `Meta+a`),
  scroll, wait. `upload` is not done yet.
- A look waits for the page to settle (no DOM change for 250 ms, nothing loading).

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

Known limits: Chromium only paints a visible window, so the window must be on screen; JavaScript
dialogs and downloads are not reported in `notes` yet; popups are blocked (one tab).

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
