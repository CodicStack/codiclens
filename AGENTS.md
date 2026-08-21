# Codiclens

macOS Spotlight-replacement launcher built with Swift, SwiftUI, and AppKit.

## Build

```bash
xcodebuild -project codiclens.xcodeproj -scheme codiclens -configuration Debug build
```

## Regenerating the emoji index

`codiclens/emoji-index.json` and `codiclens/emoji-data-license.txt` are generated,
not hand-edited. Rebuild them from the repository root:

```bash
swift Scripts/generate-emoji-index.swift
```

It downloads Unicode `emoji-test.txt` and both CLDR annotation files, joins them,
and reports the row count. Expect **1,914 rows, 2,030 skin-tone variants across
330 bases, 0 rows missing keywords** — it exits non-zero if any row comes out
keyword-less or any variant cannot be filed under a base. `--unicode` and
`--cldr` bump the versions; `--cache <dir>` reuses downloads. See
`docs/adr/0005-bundled-emoji-dataset.md`.

## Project Structure

```
codiclens/           # Main app source (Swift)
codiclensTests/      # Unit tests
Codiclens.app/       # Built app bundle
```

There are two targets, app and unit tests. There is no UI test target.
`codiclens/` is a `PBXFileSystemSynchronizedRootGroup`, so a new `.swift` file
needs no `project.pbxproj` edit.

## Rules

- No backwards compatibility hacks. Always migrate to the new solution.
- No timing hacks (asyncAfter, sleep, usleep) as bug fixes. Use event-driven or sequential solutions.
- FloatingPanel uses `.nonactivatingPanel` — never break this contract without restoring previous app focus.
- App scanning must be recursive to find apps in subdirectories (e.g., Adobe apps).
- `NSWorkspace.shared.open()` calls must be async (use `openAsync` helper) to avoid blocking the main thread.

### Visual layer

- **`Style.swift` owns every radius, material, tint and rim.** No view outside it holds
  one, and no view outside it branches on `colorScheme`.
- **`Motion.swift` owns every curve.** Exactly three exist — `entrance`, `resize`,
  `snappy` — and only the Panel appearing, the Panel dismissing and a surface
  resizing use them. Phase advances, Card content swaps and selection movement are
  instant *on purpose*: an animated highlight lags the keypress. A window frame
  change needs `Motion.resizeDuration` / `Motion.resizeTimingFunction`, because
  `NSAnimationContext` cannot take a SwiftUI `Animation`.
- **`FloatingPanel.hasShadow` must stay `false`.** AppKit derives a window shadow
  from the content's alpha mask. This Panel's content is transparent glass with soft
  edges, and that derivation traces a ragged wavy contour around it plus a ghost
  second outline. Separation is the content's job: each Slab and Card draws its own
  SwiftUI shadow.
- **No `.shadow()` on a view that fills its window.** It is clipped by the window
  bounds and renders as a hard band down two edges instead of a falloff. This is why
  `PanelLayout.margin` exists: the Panel is deliberately larger than its content, by
  enough for the entrance animation's 1.04 overshoot *and* `Style.shadowRadius`
  beyond it. Shrink the margin and both artefacts come back. `PanelLayoutTests`
  asserts the relationship.
- **The empty space inside the Panel must not be hit-testable.** The margin and the
  gap between the Slabs belong to the window, and click-outside-to-dismiss depends on
  a click there counting as outside. Three things cooperate:
  `PanelHitRegions` (where the surfaces actually are, reported by the layout),
  `FloatingPanel`'s content view declining to hit-test outside them, and a *local*
  mouse monitor in `PanelController` — the global monitor never sees these clicks,
  because the window is ours.
- **Stroke a rim *after* clipping, not before.** `overlay { strokeBorder }` followed
  by `clipShape` cuts the hairline in half and aliases along the curve.
- **A tint heavy enough to read as a colour stops glass being glass.**
  `.regular.tint(.white.opacity(0.58))` is a white wash over a blur — that is what
  "material" looks like. The blur and specular edge of `.regular` are the effect; a
  tint is only ever a nudge for legibility.
- **Emoji glyphs go through `EmojiRenderer`.** Apple Color Emoji is a bitmap font
  with strikes at 20/26/32/40/48px; an off-strike point size resamples and reads
  soft. The largest strike is 48, so a glyph slot much above 64pt looks soft unless a
  larger strike is added. `EmojiRenderer.image` is cached on the glyph **and** the box
  size — it is called from a view body, and two call sites ask for two sizes.
- **A `ForEach` id has to move when its contents do.** `EmojiSearchVM.Section` hashes
  its whole contents into its id. Every Query produces a section titled "Results", and
  while the id was the title alone a `LazyVStack` was entitled to keep the cells it
  had already built — so a filtered grid went on showing the previous Query's results
  while the Subject Card showed the right one. `ResultDisplayItem.id` is a `String`
  taken from the source for the same reason: it was a `UUID` and one initialiser
  minted a fresh one per call, re-identifying every row on every keystroke.
- **The grid and the Subject Card must draw the same glyph.** Both go through the tone
  in force — `EmojiSearchVM.displayed` for a cell, `resolvedSelection` for the Card.
  Toning is presentation only: selection, ordering and identity stay with the base,
  because a variant is never a Result.
- **Nothing builds a `ResultDisplayItem` for an Emoji.** In grid Mode a Result is a
  cell. `EmojiSearchVM.displayResults` is empty on purpose.
- Deployment target is **26.4**. Liquid Glass is unconditional — no `#available`.
- `ConcentricRectangle` exists and derives nested radii from an enclosing
  `containerShape`, but it is a `Shape` and **not** an `InsettableShape`, so it has no
  `strokeBorder`. Verified against the SDK.

## Architecture: How Components Connect

## Boot Sequence

```
codiclensApp (@main)
  └─ AppDelegate (NSApplicationDelegateAdaptor)
       ├─ Registers Cmd+Space hotkey (Carbon EventHotKey)
       ├─ Creates PanelController
       └─ Handles QLPreviewPanel responder chain
```

## Core Components

### PanelController — Window orchestrator
Owns the AppKit half: where the window sits, when it appears and disappears, who has
activation, and which clicks count as outside. Creates and manages:
- **panel** (FloatingPanel) — the *one* window, fixed at `PanelLayout.panelWidth` ×
  `panelHeight`, never resized
- **PanelPresentation** — the two values the SwiftUI content and the controller pass
  between them: `visible` (drives `Motion.panelEntrance`) and `hitRegions`
- **CommandCoordinator** — all business logic
- **QuickLookHelper** — QLPreviewPanel data source/delegate

Wires runner callbacks:
- `onHide` → `hidePanel()` — the animated dismissal
- `onPasteAndHide` → `pasteAndHide()` — `hideImmediately()`, then hands activation
  back, then fires the paste. **Never animated**: a Panel still on screen takes the
  synthesised Cmd+V.
- `onQuickLook` → `showQuickLook()` — activates app, shows QLPreviewPanel
- `onSavePanel` → `showSavePanel()` — NSSavePanel for file export
- `onShowSettings` → `showSettings()` — settings window

`coordinator.onPhaseChange` is **not** wired. It used to resize the card window; the
window no longer resizes, and the Card row's width is a SwiftUI animation driven by
`coordinator.cardCount`.

Show and hide:
- `showPanel()` centres the *Card row* on the screen the mouse is on, renders once at
  `visible == false`, then flips it inside `withAnimation(Motion.entrance)`
- `hidePanel()` drops the observers and hands activation back immediately, and lets
  only the `orderOut` wait for the exit animation's completion. `isShowing` and
  `showGeneration` are what stop a re-show racing a pending completion
- `hideImmediately()` is the no-animation path: paste, save panel, settings, teardown

Focus lifecycle lives in **FocusHandoff** — `capture`, `restore`, `yield`. Every
`previousApp` read and write in the app is in that one file.

### CommandCoordinator — State machine + execution
Owns four view models, one per search phase:
- **SubjectSearchVM** — app discovery (recursive FileManager scan) + fuzzy matching
- **ActionSearchVM** — context-sensitive actions based on selected subject
- **TargetSearchVM** — file/app targets via `mdfind` subprocess
- **ClipboardSearchVM** → **ClipboardManager** — clipboard history

Phase state machine:
```
searchingSubject ──Enter──→ executeDefaultAction + hide
       │                      (app/file/folder/text)
       │Tab
       ▼
  pickingAction ──Enter──→ executeAction + hide (final actions)
       │                      or advance to pickingTarget (non-final)
       │Tab (non-final)
       ▼
  pickingTarget ──Enter──→ executeAction + hide

searchingSubject ──"Clipboard"──→ browsingClipboard ──Enter──→ paste item
                                        │Tab
                                        ▼
                                   pickingAction (clipboard-specific)
```

Text mode: activates only when fuzzy search returns zero app matches (result-dependent, not input-dependent).

### FloatingPanel — Non-activating NSPanel
```swift
styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView]
```
Critical contract: the panel floats over other apps WITHOUT stealing macOS activation. This means the previously active app stays frontmost, which is required for paste simulation (CGEvent Cmd+V targets the frontmost app).

When Quick Look is shown, `NSApp.activate()` breaks this contract. PanelController captures `previousApp` and restores it event-driven before pasting.

### CardContainerView — Keyboard input capture
Contains a hidden `TextField` that captures all keyboard input, and the Card row.
**The keyboard lives here and nowhere else** — the Query field in the Results Slab is
display-only. Routes to coordinator:
- Enter → `submit()`, ⌥Enter → `toggleSkinTonePicker()`
- Tab → `advancePhase()` / Shift+Tab → `retreatPhase()`
- Up/Down → `moveUp()` / `moveDown()`
- Left/Right → `moveLeft()` / `moveRight()`, which mean something only in a grid
- Escape → `handleEscape()`
- Shift+Space → `triggerQuickLook()`
- Ctrl+E / Cmd+E → `toggleClipboardEdit()`
- Ctrl+J/K → `moveDown()` / `moveUp()`
- Ctrl+H/L → `moveLeft()` / `moveRight()` **first**, and only `retreatPhase()` /
  `advancePhase()` when the horizontal move meant nothing. Routing them straight to
  the Phase took Ctrl+H and Ctrl+L out of Emoji Mode. Both spellings of a
  Control-modified key are accepted, via `ControlKey.letter`.

### View Cards
- **SubjectCardView** — shows app icon/name, text preview, emoji glyph, or clipboard
  content, plus the corner chips
- **ActionCardView** — shows available actions for selected subject
- **TargetCardView** — shows file/app targets for selected action

Each Card carries a `KeyHintChip` in its bottom-trailing corner while it has the
keyboard, and only where its action has an obvious key.

### PanelView / ResultsListView — the Panel's contents
`PanelView` is the Card row, a real gap, and the Results Slab. The Slab animates in
when there are Results and out when there are not, with `Motion.resize` — except in
Emoji Mode, where the grid is never empty and the Slab is unconditional. A
display-only Query field is pinned along its bottom, because the Subject Card shows
what the Query *matched* rather than what was typed.

### ClipboardHistory / PasteboardWatcher — clipboard capture
Polls `NSPasteboard.general` every 0.5s. Stores up to 100 items as JSON in Application
Support. Images saved as PNG files in `codiclens/images/`. Text previews for Quick Look
in `codiclens/previews/`. The pasteboard is only ever read on the main thread; the
PNG re-encode goes through `ImageReencoder`, off-main in the app and inline in tests.

### QuickLookHelper — QLPreviewPanel bridge
Data source and delegate for system Quick Look. Handles keyboard events (j/k navigation, Shift+Space dismiss). Reports dismissal via `onDismiss` callback.

## Data Flow: Paste

```
User selects clipboard item → Enter
  → CommandCoordinator.submit()
  → pasteClipboardItem(): writes to NSPasteboard.general
  → onPasteAndHide callback
  → PanelController.pasteAndHide():
      1. Hide the Panel (orderOut, no animation)
      2. If codiclens stole activation (Quick Look was used):
         - Activate previousApp
         - Wait for didActivateApplicationNotification (event-driven)
         - Then fire simulateAction
      3. Else: fire simulateAction immediately
  → simulatePaste(): CGEvent Cmd+V to cgSessionEventTap
```

## Data Flow: App Launch

```
User types query → Enter
  → CommandCoordinator.submit()
  → onHide callback (panel hides FIRST)
  → executeDefaultAction(): openAsync(url)
      → Task { NSWorkspace.shared.open(url, configuration:) }
```

## Key Files

| File | Role |
|------|------|
| `codiclensApp.swift` | @main entry, AppDelegate adaptor |
| `AppDelegate.swift` | Hotkey registration, QLPreviewPanel responder |
| `PanelController.swift` | The one window: show/hide, focus lifecycle, observers, hit test |
| `PanelView.swift` | The SwiftUI content of the Panel: Card row, gap, Results Slab |
| `PanelLayout.swift` | The Panel's fixed geometry, the margin, and `PanelHitRegions` |
| `FocusHandoff.swift` | Who had activation, and how it is given back |
| `ControlKey.swift` | Folding a Control-modified key press onto its letter |
| `KeyHintChip.swift` | The keyboard hint in a Card's bottom-trailing corner |
| `CommandCoordinator.swift` | State machine, execution, paste simulation |
| `FloatingPanel.swift` | Non-activating NSPanel subclass |
| `CardContainerView.swift` | Hidden TextField keyboard capture |
| `SubjectSearchVM.swift` | Recursive app discovery + fuzzy search |
| `ActionSearchVM.swift` | Context-sensitive action loading |
| `TargetSearchVM.swift` | File/app target search via mdfind |
| `ClipboardHistory.swift` / `PasteboardWatcher.swift` | Clipboard storage, and the pasteboard poller that feeds it |
| `ClipboardSearchVM.swift` | Clipboard search/filter |
| `QuickLookHelper.swift` | QLPreviewPanel data source/delegate |
| `Subject.swift` | Subject model (app/file/folder/text/builtIn) |
| `SubjectAction.swift` | Action model, text transforms, action handlers |
| `FuzzyMatch.swift` | Fuzzy scoring (exact/prefix/substring/subsequence/levenshtein) |
| `Emoji.swift` | Emoji model, SkinTone, default-tone preference, glyph→NSImage rendering |
| `EmojiIndex.swift` | Bundled emoji dataset: lookup, grouping, skin-tone variants |
| `EmojiSearchVM.swift` | Emoji ranking, grid sections, grid keyboard model |
| `EmojiRecentsStore.swift` | Emoji Recents persistence (Application Support) |
| `EmojiGridView.swift` | Results Slab in grid Mode |
| `Style.swift` | Every radius, material, tint and rim. The only `colorScheme` branch |
| `Motion.swift` | The three curves, Reduce Motion collapse, entrance/shake/hardCut |
| `AppIndex.swift` | The app Index: background scan, atomic swap, lazy icons |
| `AppDirectoryWatcher.swift` | FSEvents watch over the application directories |

## Known issues

Real, unfixed, none urgent.

- Signing teams are inconsistent. Both targets override `DEVELOPMENT_TEAM` to
  `L256GR2793`, while the project-level default is `HHNPP7C8GB`. Will bite on a clean
  checkout.
- `SubjectCardView.clipboardEditor` takes focus from a `.task`, which is the first
  main-actor turn after the editor is inserted. That is ordering, not a delay — but it
  is still the weakest link in the focus story, and if the clipboard editor ever comes
  up unfocused, this is why.
- `Motion.resizeDuration` and `Motion.resizeTimingFunction` are unused. They are the
  AppKit spelling of `resize`, kept for the next time something animates a window
  frame; nothing does now that the Panel never resizes.
- **Ranking the whole emoji dataset is the remaining per-keystroke cost.**
  `EmojiSearchVM.rank` runs `fuzzyScore` over 1,914 names and ~15,000 keywords on the
  main thread. Measured on this dataset: **26–52 ms per keystroke unoptimised, 6–10 ms
  optimised** (it was 2× worse before `fuzzyScore` learned to reject on the length
  difference before building the Levenshtein matrix). Debug builds feel it; Release
  does not. The next move, if it is ever needed, is to stop allocating a `lowercased()`
  pair per call — the dataset is already lowercase — or to move ranking off the main
  thread. Do not "optimise" it by loosening the scoring: `FuzzyMatchTests` pins the
  tiers, and app search shares the function.
- The Panel's runtime behaviour has not been verified on screen from this environment:
  screen recording is not granted, so no screenshot was possible, and Cmd+Space is
  taken by Spotlight so the hotkey could not be driven either. The geometry and the
  hit-test rule are covered by `PanelLayoutTests`; the show/hide *window* sequence is
  not covered by anything.

### Two deliberate exceptions to the no-timing-hacks rule

Both are device or API constraints, not fixes. Do not "clean them up".

- `FocusHandoff.yield` arms a 0.5s `asyncAfter` as the deadline on
  `didActivateApplicationNotification`. The normal path is the notification, which
  cancels it. It exists because an OS notification may never arrive.
- `EffectRunner.keystrokeInterval` is a 10ms `usleep` between synthesised keystrokes,
  off the main thread. `CGEvent.post` has no delivery acknowledgement, and an unpaced
  burst outruns the receiving app's text input system, so characters go missing. It is
  the emulated device having a plausible key rate.
