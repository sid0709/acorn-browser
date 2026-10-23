# Interface design

The plan the interface is being rebuilt to, phase by phase. Phases 1 (tokens, palette, theme
picker, dark mode) , 2 (the shell in both layouts), 3 (command bar, menu bar,
history, bookmarks, settings), 4 (the ⋮ menu, boosts), 5 (tabs by drag and drop), 6 (split view, agent watch mode)
and the windows of 7 (new window, incognito) are in; the rest follow in order, each judged by `bench/run.py` afterwards.

## Context

The app (`app/Sources/App`, about 1,700 lines of SwiftUI over the CEF bridge) works, but it
looks dated. It has one hard-coded pastel wash with a brown accent, a plain 230 pt popover menu,
an address field inside each card, and zero-size hidden buttons for shortcuts. It has no dark
mode, no way to make the browser your own, and no command bar, split view, bookmarks or history.
The owner wants the feel of Arc (a tinted window, a sidebar of tabs, a theme picker, split view)
with the depth of Chromium's ⋮ menu, while staying as light as Chromium. **Only the browser
app's interface changes.** The harness, runner and agent protocol stay as they are.

The owner chose:
- **Both layouts, both modernized.** One is an Arc-style vertical sidebar, the other Google-style
  horizontal tabs. The current `verticalLayout` toggle is kept but redesigned.
- **Menu contents:** New tab / New window / Incognito, Bookmarks, History, Extensions,
  Translate, Pin, a Tab submenu, and Settings.
- **Features:** tab grouping and ungrouping by drag and drop, split view, a theme picker,
  history, and a Settings window.

Hard constraints, from CLAUDE.md and the code:
- Mission completion comes first. The agent tab (`BrowserModel.shared`) must stay on screen,
  because Chromium paints only visible views, and at the default window size its viewport must be
  no narrower than today's (about 896 pt wide). `bench/run.py` drives the agent tab directly
  through the socket (`AgentServer` → `AgentDriver`), not through `AgentRunner`, so any "the
  agent is driving" state must come from `AgentDriver.attach()`/`detach()`.
- `build.sh` compiles `Sources/App/*.swift`, which is not recursive, so new Swift files stay
  flat in `Sources/App/`.
- Commits carry both Co-Authored-By lines from CLAUDE.md. Each phase is a branch named by the
  rules in CLAUDE.md and reaches `main` through a PR.

## Design direction

The principle is **"the page is the hero, the shell is the person's."** The chrome recedes into
one tinted canvas that the person picks. Content sits on soft, floating cards. Every control
earns its place.

### Design tokens (`Theme.swift`, rewritten)

- **Spacing:** a 4 pt grid. `xs 4 · s 8 · m 12 · l 16 · xl 24`. The window gutter is 8.
- **Radii:** card 10 · row 8 · tile 10 · popover 14 · pill capsule.
- **Type:** SF Pro, system font only.
  - Row / body: 13 regular.
  - Active tab: 13 medium.
  - Secondary: 12.
  - Caption / shortcut: 11.
  - Section title: 11 semibold, uppercase-free, 60% ink.
  - Panel title: 15 semibold.
- **Elevation:** a card has a 1 px hairline at 6% ink, plus shadows of (y1 r2 6%) and (y8 r24 8%).
  Popovers use the second shadow only, at 14%.
- **Icons:** SF Symbols at medium weight, 14 pt in toolbars and 13 pt in rows, 28×28 hit targets.
- **Motion:**
  - Layout changes: `.snappy(duration: 0.22)`.
  - Hover: `.easeOut(0.12)`.
  - Every animation honors `accessibilityReduceMotion`.
  - The only repeating animation is the agent glow, and only while the agent drives.
- **Color is derived, not hard-coded.** A `Palette` value is computed from the theme (1–3 base
  colors, intensity, grain, appearance):
  - `canvas`: a gradient of the base colors.
    - Light appearance: lightness 90–96%.
    - Dark appearance: lightness 12–20%.
    - Intensity scales saturation.
  - `ink` and `inkSecondary`: chosen for at least 4.5:1 contrast against the canvas.
  - `card`: white, or `#1E1E20` in dark.
  - `selection`: white at 72%, or white at 10% in dark.
  - `hover`: ink at 6%.
  - `accent`: the primary base color, adjusted until it reaches 4.5:1 against the card.
  - `agent`: the existing sparkle gradient, kept as the brand mark.

### Theme system (new `ThemeStore.swift`, `ThemePicker.swift`)

- `ThemeStore` (`ObservableObject`) holds `colors: [HSB]` (1–3), `intensity`, `grain`, and
  `appearance` (system/light/dark). It is persisted as JSON in `@AppStorage("theme")`. Each window
  gets its palette through `.environment(\.palette, …)`, so a change repaints only the views that
  read the palette.
- **Presets** (8 swatches):
  - Acorn (sand/terracotta, the brand)
  - Sunset (today's peach→pink→lavender wash, so the current feel survives)
  - Mist
  - Sage
  - Lilac
  - Rose
  - Graphite (dark)
  - Midnight (dark)
- **Picker** (an Arc-style popover from the sidebar footer, or from the menu's Settings ›
  Appearance):
  - A row of swatches, plus a "custom" ring.
  - A 2D color pad (x = hue, y = saturation) with 1–3 draggable knobs. `+`/`−` add or remove a
    gradient stop.
  - Intensity and Grain sliders.
  - A System / Light / Dark segmented control.
  - Every change previews live on the window.
- **Grain:** one 128×128 noise tile is generated once with `CGImage` and tiled over the canvas
  at `grain × 0.08` opacity. That is a single image, with no per-frame cost.
- Incognito windows ignore the theme and use a fixed graphite palette with an Incognito badge.

## The shell, in two layouts (`ContentView.swift`, new `Sidebar.swift`, `WindowChrome.swift`)

Shared pieces:
- **`WindowChrome.swift`:**
  - The hand-drawn `WindowControls` and `WindowDragArea`, moved out of `ContentView`. The note
    about the compositor bug is kept.
  - The new `PageToolbar` (a 40 pt card header) with ← → ↻, a **domain-only URL pill** (lock,
    host, copy-link button, ☆ bookmark), and ⋮ on the right. Clicking the pill opens the command
    bar on the current tab's URL. The full URL never sits in the chrome.
- **`PageCard`** (the former `BrowserCard`): the page in a 10 pt card with a 2 pt top progress
  hairline in `accent`, and the `FindBar` restyled as a floating capsule at the top right.
- **Agent glow:** while `tab.isDriven` (new, set by `AgentDriver.attach/detach`), the agent tab's
  card gets a 2 pt angular-gradient stroke in the sparkle colors. It turns once every 4 s, and is
  static under Reduce Motion.

**Sidebar layout** (Arc):

```
┌ Sidebar 248 (resizable 200–360) ┐┌──────── PageCard ────────┐┌ Agent 340 ┐
│ ● ● ●   ◧        ‹  ›  ↻         ││  (no toolbar: the sidebar││           │
│ [🔒 wikipedia.org        ⧉ ☆]    ││   holds navigation)      ││           │
│ ┌──┐┌──┐┌──┐┌──┐  favorites       ││                          ││           │
│ └──┘└──┘└──┘└──┘  (pinned tabs)   ││                          ││           │
│ ✦ Agent · working…                ││                          ││           │
│ ▾ 📁 Work            (group)      ││                          ││           │
│    ▢ Docs                         ││                          ││           │
│ ─────────────                     ││                          ││           │
│ ＋ New Tab                         ││                          ││           │
│ ▢ Tab · ▢ Tab …                   ││                          ││           │
│ 🎨  ⬇  🕘                  ⋮  ＋   ││                          ││           │
└───────────────────────────────────┘└──────────────────────────┘└───────────┘
```

- The sidebar is not a card. It sits directly on the canvas, Arc-style.
- **Rows:** 34 pt tall, 16 pt favicons, `selection` fill plus a soft shadow on the active row.
  Close × and audio appear on hover.
- **Favorites:** a 4-column grid of 44 pt tiles (3 columns when narrow), built from
  `isPinned`. The active tile gets a 1.5 pt accent ring.
- **Groups:** shown as folders. Each has a disclosure chevron, a color dot and the name (renamed
  inline with a double click), and its members are indented 12 pt.
- **The agent tab** is a dedicated row under the favorites. It has a sparkle icon, a live status
  ("Working · step 4", "Idle"), cannot be dragged into groups, and cannot be closed.
- **Footer:** theme 🎨, History 🕘, ⋮ menu, and ＋.
- **Hiding:** ⌘S hides the sidebar. While it is hidden, a 6 pt hot edge on the left reveals it as
  an overlay on hover (Arc's "peek").
- **Viewport guard:** while the agent tab is driven and on screen, the sidebar drops to peek mode
  and comes back on detach. The page keeps at least today's width.

**Top layout** (modernized Google style):

- The tab row sits on the canvas, not in a card.
  - Tabs are 32 pt capsules. The active tab has a `selection` fill and shadow, the others are
    text-only with a hover fill.
  - Pinned tabs are 32×32 favicon squares on the left.
  - Groups get a colored label chip, and a bracket underline in the group color.
  - ＋ comes last. "✦ Ask" sits on the right with a live dot while the agent works.
- The page card carries the `PageToolbar`.
- Window controls sit at the left of the tab row.

The agent panel (`ChatSidebar.swift`, `ModelPicker.swift`) is restyled with tokens only, and its
behavior is unchanged:
- It becomes a 340 pt card.
- The header gets a model chip.
- The person's messages become accent bubbles. Steps form a slim timeline with sparkle dots. The
  Done and Needs-attention cards use tinted fills from the palette.
- The composer becomes a floating 14 pt-radius field with the send/stop button inside it.
- ⌘K still toggles the panel.

## Command bar (new `CommandBar.swift`)

- ⌘T opens it as a **new tab**. ⌘L (or a click on the URL pill) opens it on the **current tab**.
- It is a centered floating panel, 600 pt wide with a 14 pt radius, over a dimmed page. Esc
  closes it, and nothing is created if it closes empty.
- Results are grouped and arrow-key navigable. They are ranked locally, with no network
  suggestions (light and private):
  1. Go to the typed URL, or search for it with the engine from Settings.
  2. Switch to an open tab.
  3. Bookmarks.
  4. History, by recency × frequency.
  5. Commands: Split view, Toggle sidebar, Theme, Zoom, Pin, New window, Incognito, Settings.
  6. **"✦ Ask the agent: …"**, which hands the text to `runner.submit` and opens the agent panel.
- `BrowserModel.resolve` moves here and takes the engine from Settings, so Google is no longer
  hard-coded.

## Menu bar and shortcuts (`AcornBrowserApp.swift`)

- The zero-size hidden `Button`s in `ContentView` are replaced with a real `.commands {}` menu
  bar: File, Edit, View, Tabs, Bookmarks, History, Window, Help. Every shortcut shows in its menu.
  - ⌘T new tab, ⌘N new window, ⇧⌘N Incognito window
  - ⌘W, ⌘L, ⌘F, ⌘P, ⌘D, ⌘= / ⌘- / ⌘0, ⌘S, ⌘K, ⌘\ split, ⌘⇧C copy link, ⌘Y history, ⌘,
- A `Settings { SettingsView() }` scene is added.
- Commands reach the key window's store through `@FocusedObject` / `focusedSceneObject`.
- Verify that each shortcut fires while the Chromium view has focus. Today's hidden buttons do,
  and menu key equivalents go through the same `performKeyEquivalent` path.

## Main menu ⋮ (`BrowserMenu.swift`, rewritten)

This is Chromium's information architecture with a modern surface: a 320 pt popover in the
palette, with sections and subpages that slide in (state-driven, no `NavigationStack`).

```
[ ＋ New tab ] [ ⧉ New window ] [ 🕶 Incognito ]          ← three tiles
This page
  Zoom          (−)  100%  (+)  │  ⛶                     ← inline stepper, fullscreen
  ☆ Bookmark this page                         ⌘D
  📌 Pin tab / Unpin tab
  ◫ Open in split view                         ⌘\
  🔍 Find in page                              ⌘F
  文 Translate page                       (disabled off http/https)
  ⎙ Print                                      ⌘P
  🔗 Copy link                                ⇧⌘C
Browser
  ☆ Bookmarks                                   ›   (list, search, open, remove)
  🕘 History                                    ›   (recent 20, "Show all" ⌘Y)
  ▤ Tab                                         ›   (duplicate, group, ungroup, move to split,
                                                     close others / to the right)
  🧩 Extensions                                 ›
  ◧ Layout          [ sidebar | top ]               (segmented, replaces today's picker)
──────────────────────────────────────────────────
ⓘ About Acorn                               ⚙ Settings  ⌘,
```

- **Translate** opens `https://translate.google.com/translate?sl=auto&tl=<lang>&u=<url>` in the
  same tab. `<lang>` comes from Settings (the system language by default). It needs no Chromium
  translate service and adds no weight.
- **Extensions** is limited by the engine. The views are created with `CEF_RUNTIME_STYLE_ALLOY`
  (`ChromiumBrowserView.mm:679`), and CEF dropped Alloy extension support, so Web Store
  extensions cannot load as things stand. The plan:
  - The menu row ships with a subpage listing **Site boosts**: per-site CSS and JS the person
    writes, injected on load through the existing `sendDevToolsMethod`
    (`Page.addScriptToEvaluateOnNewDocument`). This works the way Arc Boosts do, and is cheap.
  - A separate, time-boxed spike tries Chrome-style browsers for the person's tabs only, which
    would make `chrome://extensions` and the Web Store work. The agent tab stays Alloy so
    `AgentDriver` input is untouched. If the spike works, the subpage gets "Manage extensions".
    If not, Boosts is the answer.

## Library: history, bookmarks, settings (new `Library.swift`, `SettingsView.swift`)

- **`HistoryStore`:**
  - Appends `(url, title, time)` from `browserViewDidUpdateState` when a load finishes.
  - Skips incognito tabs and the agent tab while it is driven, so the agent's runs don't flood
    history.
  - Capped at 5,000 entries, deduplicated by URL with a visit count.
  - Saved as JSON in `~/Library/Application Support/com.acorn.browser/history.json`, debounced
    2 s, off the main thread.
- **History panel** (⌘Y): a sheet with search, a `LazyVStack` grouped by day, and "Clear
  browsing data…" (history and cookies, the latter through
  `Network.clearBrowserCookies` / `clearBrowserCache`).
- **`BookmarkStore`:**
  - A flat list plus folders, stored in `bookmarks.json`.
  - The ☆ in the URL pill fills when the page is bookmarked. ⌘D toggles it.
  - The panel opens from the menu and the command bar.
- **`SettingsView`** has four tabs:
  - Appearance: the theme picker embedded, plus appearance.
  - Tabs & Layout: sidebar or top, sidebar width, and where new tabs open.
  - Search: engine (Google, DuckDuckGo, Bing, Kagi) and translate language.
  - Privacy: clear data.
  - (The agent model picker stays in the agent panel.)

## Tabs: drag and drop, grouping, ungrouping (new `TabDrag.swift`; `TabStore.swift`, `TabStrip.swift`, `Sidebar.swift`)

- Every tab row and pill takes a drag gesture; each drop target registers its frame, and the
  target under the pointer decides, along the main axis:
  - **Outer 25% at either end:** reorder, inserting before or after the target.
  - **Middle 50% of a tab:** group the two tabs. A new group appears with a highlight pulse, and
    the name field focuses.
  - **On a group header or folder:** join that group.
  - **Into ungrouped space** (between rows outside a group, or the tab list's empty area):
    leave the group. A group left with no members dissolves (`removeFromGroup` already does this).
  - **Onto the favorites grid:** pin. **Out of the grid:** unpin.
- A 2 pt accent insertion line or a group-tint highlight shows what will happen before the drop.
- New `TabStore` methods: `move(_:before:)`, `move(_:after:)`, `group(_:with:)`, and
  `ungroup(_:)`. They reuse `addToGroup` and `removeFromGroup`, and all run inside
  `withAnimation(.snappy)`.
- The agent tab is not draggable and refuses drops.
- The top layout's middle-click close (the `NSEvent` monitor in `TabStrip`) is kept.

## Split view (new `SplitView.swift`)

- `TabStore` gets `split: (left: UUID, right: UUID)?`, a `ratio` (0.25–0.75), and `focusedPane`.
- It renders as two `PageCard`s, each with its own `PageToolbar`. A 6 pt drag handle sits
  between them and resizes on drag (with an `NSCursor.resizeLeftRight` hover). The focused pane
  gets the 1.5 pt accent outline, as in Arc's screenshot.
- In the sidebar it shows as one paired row with two favicons and two titles (Arc's
  "Art – M… | Are.na"). In the top layout it shows as two pills joined by a ◫ glyph.
- Entry points:
  - ⌘\ or the menu's "Open in split view" pairs the current tab with the next one, or a new tab.
  - Dragging a tab onto the page's right edge opens a split.
  - The pair's ⋯ menu has "Close split" and "Swap".
- **Agent watch mode** solves a real failure mode as well as being a design touch. When the
  agent tab is driven while the person is on another tab, the agent tab docks into the right
  pane automatically. Chromium keeps painting it, and the person watches it work. The split
  undocks on detach unless the person kept it. The viewport guard above still applies: in this
  mode the sidebar goes to peek and the split ratio leaves the agent pane at least 896 pt wide.

## New window and Incognito (`AcornBrowserApp.swift`, `TabStore.swift`, Chromium bridge)

- `TabStore.shared` becomes the **main window's** store, which owns the agent tab. Other windows
  get `TabStore(kind: .normal | .incognito)` with no agent tab. `ContentView` takes its store
  from a `WindowGroup(for: WindowKind.self)` value. `isAgentTab` and `active` lose the
  `BrowserModel.shared` fallback outside the main window.
- **Bridge** (`ChromiumBridge.h`, `ChromiumBrowserView.mm`):
  - Add `- (instancetype)initWithURL:(NSString *)url incognito:(BOOL)incognito`.
  - Incognito views share one `CefRequestContext::CreateContext` with an empty `cache_path`,
    which keeps it in memory only. It is created lazily and released when the last incognito
    window closes.
  - Normal views keep the global context, so nothing changes for the agent.
- An incognito window uses the graphite palette, shows a 🕶 badge in the sidebar or tab row,
  records no history, and allows no bookmark writes unless the person explicitly saves one.

## Lightweight by construction

- Native SwiftUI and AppKit only: no web-rendered chrome, no new dependencies, no new
  processes.
- When idle, no animation runs and no timer ticks. The agent glow runs only while the agent
  drives, and pauses when the window is not key.
- The canvas is one gradient over one behind-window blur, and its glows are static gradients.
  The glass panes (sidebar, page card, agent panel, and what floats: the command bar, the find
  bar, suggestions) are the only blurs, a handful per window; rows and tabs get no blur (the one
  in use is a `GlassBead`, a fill with a lit rim). Grain is one cached tile.
- Long lists (history, the command bar, many tabs) use `LazyVStack`. Favicons stay per tab.
- Stores write JSON debounced and off the main thread. Nothing loads at launch beyond the theme,
  and history loads lazily on the first command bar or History open.
- Target: idle CPU stays at 0%, and the app's own memory (minus Chromium) rises by less than
  15 MB, measured in Activity Monitor before and after.

## Delivery: phases (one PR each, each one building and bench-checked)

1. **Foundation:** tokens, `Palette`, `ThemeStore`, `ThemePicker`, dark mode. Every existing view
   reads tokens, so the look changes everywhere at once.
2. **Shell:** `WindowChrome`, `PageCard`/`PageToolbar`, the modernized top layout, `Sidebar`
   (favorites, folders, agent row, footer, peek), the agent glow plus `isDriven` (a small hook in
   `AgentDriver.attach/detach`), and the viewport guard. Restyle the agent panel.
3. **Command bar, menu bar, Library:** `CommandBar`, `.commands`, `HistoryStore`,
   `BookmarkStore`, the History panel, and `SettingsView`.
4. **Main menu:** the rewritten `BrowserMenu` with tiles, zoom, bookmark, translate, pin, the Tab
   / Bookmarks / History / Extensions (Boosts) subpages, and About and Settings.
5. **Tabs:** drag and drop reorder, group, ungroup, pin and unpin in both layouts.
6. **Split view:** plus agent watch mode.
7. **Windows:** New window, Incognito (the bridge request context), and the Chrome-style
   extensions spike, reported back before anything ships from it.

## Files

- **Rewritten:**
  - `Theme.swift`
  - `ContentView.swift` (shell only)
  - `BrowserMenu.swift`
  - `TabStrip.swift` (top layout)
- **Modified:**
  - `TabStore.swift`
  - `BrowserModel.swift` (`isDriven`, `isIncognito`, a history hook)
  - `ChatSidebar.swift`
  - `ModelPicker.swift`
  - `AcornBrowserApp.swift`
  - `AgentDriver.swift` (two lines that set `isDriven`)
  - `ChromiumBridge.h` and `ChromiumBrowserView.mm` (the incognito initializer)
  - `app/README.md` ("Interface" section)
- **New, flat in `Sources/App/`:**
  - `ThemeStore.swift`
  - `ThemePicker.swift`
  - `WindowChrome.swift`
  - `Sidebar.swift`
  - `CommandBar.swift`
  - `Library.swift`
  - `SettingsView.swift`
  - `TabDrag.swift`
  - `SplitView.swift`
  - `Boosts.swift`
- **Reused as they are:**
  - `TabStore.newGroup/addToGroup/removeFromGroup/toggleCollapse/rename/recolor/togglePin`
  - `BrowserModel` zoom and find
  - `FindBar`
  - `WindowControls`/`WindowDragArea`
  - `ChromiumBrowserView.sendDevToolsMethod`, for boosts and clearing data

## Verification (on a Mac with Xcode)

1. `app/scripts/build.sh run`. Then walk both layouts in light and dark, with every preset,
   grain at 0 and at max, and Reduce Motion on and off.
2. Shortcuts: ⌘T, ⌘L, ⌘F, ⌘D, ⌘S, ⌘\, ⌘K, ⌘Y, ⌘, and zoom, all fired with focus inside the page.
3. Drag and drop: reorder, group, join, ungroup, pin and unpin, in both layouts. Confirm the
   agent tab refuses all of them.
4. Split view: resize, swap, close. Check agent watch mode by starting a run from another tab.
5. Incognito: log in to a site, close the window, open a new incognito window, and confirm you
   are logged out. Confirm no history entries were written. Confirm the main window is still
   logged in.
6. Agent safety:
   - `app/Tests/agent_smoke.py` passes all 19 checks.
   - Check `window.innerWidth` during a run (from the smoke test's `observe`) and confirm it is
     ≥ today's at the default window size, in both layouts.
   - `bench/run.py` scores no lower than the last baseline. Traces and results stay out of git.
7. Weight: Activity Monitor shows 0% CPU while idle, and app memory rises by less than 15 MB.
   Instruments' SwiftUI template shows no body re-evaluations while idle.
