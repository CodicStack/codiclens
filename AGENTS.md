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
- **Share is a Target list, not a popped system menu.** The sharing service is the
  Target, chosen in the Target Phase like any other. Still built from
  `NSSharingService.sharingServices(forItems:)`, deprecated since macOS 13 in favour of
  `standardShareMenuItem` and still returning the full list on 26. No "Copy Link" and no
  "More…" rows.
- **Plain text is shared as a temporary `.txt` file**, named from its first line, because
  AirDrop refuses a string: `NSSharingService(named: .sendViaAirDrop).canPerform(withItems:
  ["text" as NSString])` is **false**, and an `NSString` payload offers only Mail, Messages,
  Notes, Freeform, Journal and Reminders. **Text that is a URL is shared as an `NSURL`
  instead** — that payload gets AirDrop *and* Add to Reading List.
- **QR Code is an Action, not a Share Target.** A QR code is a form of the text, not a
  recipient of it. Its output becomes a new Clipboard image at the top of history and the
  Subject retargets to it, exactly as OCR retargets to OCR Text. Absent when the text
  exceeds the Core Image encoder's UTF-8 capacity, and never offered on Emoji. Capacity
  follows an actual encoder attempt, not a character-count estimate.
- **Rotate is in place and must not hide the Panel.** Rotate Left / Rotate Right are Final
  Actions on an image Subject that rotate without asking, as Finder does; the Subject stays,
  the Panel stays, and a rotated Clipboard Item is **not** moved to the top of the history.
  Same no-`.hide` rule as OCR. Everything else — markup, crop — is **Open in Preview**. See
  `docs/adr/0011-image-edits-rotate-in-process-everything-else-is-preview.md`. Normal
  one-frame 8-bit PNG and TIFF files rotate in their original format; higher-precision
  sources are rejected rather than reduced to 8-bit. JPEG rotates by changing orientation
  metadata while ImageIO copies its compressed image data losslessly. Multi-frame or
  auxiliary-image sources are rejected so animation, pages, depth data and gain maps are
  never silently discarded.

### Visual layer

- **`Style.swift` owns every radius, material and tint**, and nothing outside it
  branches on `colorScheme`. A Card needs no branch: bare glass adapts itself.
- **A Card is bare `.glassEffect(.regular)` in a rounded rect — nothing else.** Never add
  a rim, a `.shadow`, a `.clipShape`, a gradient, a specular wash or an inner shadow.
  Lensing, the specular rim and the shadow are the material's own job (WWDC25 219);
  clipping glass cuts its shadow into a grey halo (Apple forum 797806); a fill behind
  glass is banned outright (WWDC25 310). All of them were on the Card until 2026-09-11
  and it read as frosted plastic.
- **Every Card is untinted `.regular` glass, and focus is Emphasis.** The *unfocused* Card
  is inset by `Style.unfocusedCardShrink` — 10pt on each side in **layout**, so a 200pt Card
  is drawn at 180 — with its content at `Style.unfocusedContentOpacity`; the focused one is
  full size, and the change is instant via `.animation(nil, value: focused)`. Never a
  transform: `GlassEffectContainer` builds its glass shapes from layout frames and ignores a
  `.scaleEffect`'s anchor, so glass and content shrank about different anchors and the content
  ended up ~10pt off-centre.
  Never show focus with a tint, a rim, a shadow, a Lamp or a beam — an accent-tinted Card
  was built and rejected on sight (2026-09-11); the app carries no colour.
- **One `GlassEffectContainer` holds all glass** — three Card tiles and the Results Slab
  — with `spacing` **below** the inter-Card gap so nothing merges, and `.glassEffect` on
  the children, never on the container. Cards never fuse — no `glassEffectUnion`: the
  Panel is meant to read as three separate tiles with a gap, not one body (`CONTEXT.md`,
  **Card**).
- **Arrival is `.glassEffectTransition(.matchedGeometry)` on `Motion.resize`**: a new Card
  grows out of the one before it; its content hard-cuts; `.identity` under Reduce Motion.
- **`Motion.swift` owns every curve, in two categories.** Three **Transition** curves —
  `entrance`, `resize`, `snappy` — carry a change the user caused; Phase advances, Card
  content swaps and selection movement are instant *on purpose*. **Decoration** is now
  the Loading Ring alone, absent under `Motion.isReduced`; `Motion.isTransparencyReduced`
  is **deleted**, with the beam it existed for. ADR 0003's beam sections are
  history, not guidance.
- **A text Subject gets a monochrome fill in the Card's *content* layer**, never a
  tinted glass. See `docs/adr/0009-cards-are-bare-glass.md` and `CONTEXT.md`.
- **The Loading Ring is not a progress indicator.** A constant-length 270° arc that
  turns, in both of the Panel's waiting states. Neither Vision nor `mdfind` reports
  progress, so a ring that *fills* would be claiming something the app cannot back.
- **`FloatingPanel.hasShadow` must stay `false`.** AppKit derives a window shadow
  from the content's alpha mask. This Panel's content is transparent glass with soft
  edges, and that derivation traces a ragged wavy contour around it plus a ghost
  second outline. Separation is the content's job: the Results Slab draws its own
  SwiftUI shadow, and a Card's native glass casts its own — never give a Card a
  `.shadow()`.
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
- **A Slab inside a window sized to the worst case must carry a *definite*
  height.** `maxHeight` is flexible, so a Slab given one takes every point the
  Panel reserved for it — which is how the Results Slab came to be a mostly-empty
  pane with the Query field floating under the divider. The Slab hugs
  (`fixedSize(vertical:)`) and the scrolling area inside it is given a definite
  `PanelLayout.resultsAreaHeight(contentHeight:chromeHeight:)`. That also keeps the
  proposal definite all the way down to the `LazyVStack`: hugging a lazy container
  by proposing it an unspecified height makes it build all 1,914 cells to answer,
  so the content heights are **arithmetic** (`EmojiGridView.contentHeight`,
  `PanelLayout.listContentHeight`), not measurements. Where an intrinsic piece of
  furniture has to appear in that arithmetic it is rounded *up* — see
  `PanelLayout.resultsHeaderHeight`. `PanelLayoutTests` pins the sums.
- **The Query field is a bar, not a row.** `PanelLayout.queryFieldHeight` and
  nothing else, pinned along the Slab's bottom edge in every Mode; the Results
  area above it takes all the variable height. It is also the **only** place the
  Query is spelled out — the results header, the empty and searching states and
  the Action and Target Card placeholders all used to repeat it, which put the
  same string on screen twice and wrapped a long Query over three lines. One
  Query on screen at a time; everything else names what it *matched*.
- **"No results" is a claim, and a Mode has to be entitled to it.**
  `CommandCoordinator.canReportNoResults` is that entitlement and
  `isSearchInFlight` is the "Searching…" one. Clipboard, Emoji and Action search
  match in memory, so zero matches is true the instant the key lands and the
  message must not be delayed. In Subject search the row carries a "⌘E use as
  text" `KeyHintChip`, the only way a Query becomes text. Subject search matches
  the app Index, and until the first scan lands the Slab shows the Query bar
  **alone** — no message row,
  which is the shortest Slab there is (`PanelLayout.queryOnlyResultsHeight`).
  Its list below the apps answers once typing pauses, and until it has the Slab
  says nothing either: `SubjectSearchVM.hasAnswered` waits for both, so "No
  results" never flickers between keystrokes and then turns into files.
  Target search answers out of process and says "Searching…" instead, and OCR
  — which is not a search at all — says "Reading text…" off
  `CommandCoordinator.isOCRInFlight`. Subject
  Results used to be withheld for 600ms by a debounced visibility flag on top of
  all that, which left "No results" as the only thing the Slab could draw in the
  meantime: every search said no and then changed its mind. A debounce cannot
  fix that, because a debounce is what it was.
- **A matched name is marked with an underline, in `highlightedName`.** Weight
  was tried and is no difference at all against a selected row, whose title is
  already bold. The subsequence tier only marks up when the *whole* Query is a
  subsequence of the name, so an Emoji found by its keywords — which have nothing
  to underline in the CLDR name — degrades to plain text instead of marking the
  two characters that happen to line up. A Result's subtitle is marked up only
  where it names the thing; `ResultDisplayItem.highlightsSubtitle` decides, and
  it is false for a derived subtitle like a clipboard entry's relative
  timestamp.
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
- **Emoji Mode builds no `ResultDisplayItem`.** In grid Mode a Result is a cell, and
  `EmojiSearchVM.displayResults` is empty on purpose. The one Emoji row is in Subject
  search's list below the apps (`ResultDisplayItem(emoji:base:)`): the glyph in the
  tone in force, through `EmojiRenderer`, with the base's id.
- **Every picture of a file's contents goes through `Thumbnails`** — Quick Look's
  `QLThumbnailGenerator`, `.thumbnail` representation only. A `Subject`, an
  `ActionTarget` and a `ResultDisplayItem` carry a `thumbnailURL` beside their icon: a
  file's own URL, or a Clipboard Image's stored PNG (`Subject(clipboardItem:imageURL:)`,
  made only where the history is at hand — `CommandCoordinator.clipboardSubject(for:)`
  and the list below the apps in `SubjectSearchVM` — because only the history
  knows the path). `ThumbnailImage` draws the icon at once and swaps the thumbnail in
  when it lands — no fade — and asks from `.task`, so only rows the `LazyVStack`
  builds ask at all. Requests are the slot's side (`PanelLayout.resultIconSize`,
  `Style.cardIcon`) at `displayScale`. The cache is an `NSCache` checked against the
  file's modification date and size, because Rotate and Preview write in place; a
  view's first frame is the last thumbnail made, so a row rebuilt by a keystroke does
  not flash its icon. Only regular files are asked about — a folder or an app is its
  icon. The Subject Card keys its thumbnail on `subject.id`, which is how a Rotate's
  fresh Subject makes it look at the file again. The Clipboard browser's full-size
  Card preview is not a thumbnail and reads the stored PNG directly.
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
       ├─ Starts the File Index (FileIndex.shared.start(); stop() on terminate)
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
- `onOCRText` → `coordinator.receiveOCRText(_:)`
- `onQRCode` → `coordinator.receiveQRCode(_:generation:)`
- `onImageRotation` → `coordinator.receiveImageRotation(...)`

These three callbacks answer the coordinator across the Effect seam. The runner owns
Vision and image processing, so `CommandCoordinator` does neither. Image callback
generation IDs discard answers from a reset Panel session.

`coordinator.onPhaseChange` is **not** wired. It used to resize the card window; the
window no longer resizes, and the Card row's width is a SwiftUI animation driven by
`coordinator.cardCount`.

Show and hide:
- `showPanel()` calls `coordinator.reset()`, which stands the **Last Subject** if
  there is one (see CommandCoordinator below), centres the *Card row* on the screen
  the mouse is on, renders once at `visible == false`, then flips it inside
  `withAnimation(Motion.entrance)`
- `hidePanel()` drops the observers and hands activation back immediately, and lets
  only the `orderOut` wait for the exit animation's completion. `isShowing` and
  `showGeneration` are what stop a re-show racing a pending completion
- `hideImmediately()` is the no-animation path: paste, save panel, settings, teardown

Focus lifecycle lives in **FocusHandoff** — `capture`, `restore`, `yield`. Every
`previousApp` read and write in the app is in that one file.

### CommandCoordinator — State machine + execution
Owns four view models, one per search phase:
- **SubjectSearchVM** — Subject search, as two lists that read as one. Up to five
  apps and Built-ins, fuzzy-matched against the app Index on the keystroke and
  always on top. Below them, **once typing pauses** (a 120ms Combine debounce, then
  `searchSources()`), one list ranked by score mixing File Results (File Index),
  Clipboard Items (text ones, `ClipboardSearchVM.scored`) and Emoji
  (`EmojiSearchVM.scored`) — `SourceSearch` ranks it off the main actor on
  `fuzzyScore`'s scale, files up to 50, Clipboard and Emoji capped at three each,
  no priority between Sources. It lands once per Query and is never ranked again;
  the next keystroke withdraws it rather than leave rows answering the previous
  Query, and a late answer for a Query that has moved on is dropped. Each row names
  its Source (`ResultDisplayItem(file:)`, `(clipboardResult:)`, `(emoji:base:)`,
  ids prefixed by Source). Every Source's switch in `SourceStore` is read on every
  search; folder switches are the File Index's own. See ADR 0012.
- **ActionSearchVM** — context-sensitive actions based on selected subject
- **TargetSearchVM** — file/app targets. The search itself is `FileTargetSearch`:
  the **File Index first**, shown at once while "Searching…" still holds, then the
  priority-folder and system-wide `mdfind`s, run side by
  side, each read line by line and stopped at its `Scope.lineCap`, minus every path
  the File Index already gave, appended below it so nothing on screen moves. Only
  the ranked top 50 get an icon. Their thumbnails are not made here; a row asks
  `Thumbnails` once it is on screen. The next keystroke, and leaving file search,
  cancel it — every `mdfind` it started is terminated. Stages are `OSSignposter` intervals
  under the "Search" category; `FileTargetSearchTimingTests` times them against the
  real index and is skipped unless `TEST_RUNNER_CODICLENS_TIME_FILE_SEARCH=<runs>`
  is set.
- **ClipboardSearchVM** → **ClipboardManager** — clipboard history

Phase state machine:
```
searchingSubject ──Enter──→ executeDefaultAction + hide
       │                      (app/file/folder/text, a Clipboard Item row pastes,
       │                       an Emoji row inserts, or the Last Subject)
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

A file becomes a Subject two ways, and neither is a file browser — see
`docs/adr/0008-a-file-can-be-a-subject.md`. A **Path Subject** is a Query
beginning `/` or `~`, resolved by `PathSubject` to exactly one file or folder;
those two prefixes cannot collide with an app name, so none of the Index's
gates move for one. **Use as Subject** is a non-Final Action that promotes a
file-or-app Target into the Subject and lands back on `.pickingAction`. ADR 0012
added a third, the list below the apps: a File Result is a Subject once chosen,
resolved again through `PathSubject.subject(for:)` as Enter or Tab lands
(`CommandCoordinator.chosen`) — a file gone since it was indexed is not acted on.

Rows of the list below the apps act as their own Mode would. A File Result opens
on Enter and Tab gives its file Actions, Share among them. A Clipboard Item pastes
on Enter; an Emoji inserts in the tone in force and becomes recent. Both become the
Last Subject, and a file clears it. Shift+Tab from their Actions returns to
Subject search (`isSubjectFromSearch`), not to the Clipboard browser or the grid
they never came from.

OCR returns `[.ocr(url)]` and **no `.hide`** — the OCR Text lands *in* the Panel — and
`EffectRunner` awaits Vision before answering through `onOCRText`. QR Code and Rotate
also run behind the Effect seam and return no `.hide`; their work uses one serial queue
so consecutive rotations reach disk in command order. `isOCRInFlight` and
`isImageActionInFlight` gate a second Enter while their respective answer is pending.

Text mode is **⌘E, and nothing else** (`docs/adr/0012-files-in-subject-search-text-mode-is-cmd-e.md`).
Zero app matches is "No results" — offering ⌘E as a hint — never a text Subject.
⌘E in Subject search with a non-empty Query opens the editor with the Query in it,
whether or not anything matched and for a path Query too; saving stands the text
as the only Result (`SubjectSearchVM.standAsText`), so Enter copies it and Tab
opens its Actions. Escape in the editor discards it; Escape on the saved text goes
back to what the Query matched. The next keystroke is a new Query: the text was
written in the editor, not in the Query. `hasAnswered` — the Index landed and the
list below the apps answered this Query — gates only "No results", the Card's "No
match" and the shake. A list landing while text stands is kept for Escape.

**Last Subject** (`CONTEXT.md`): Enter or a Final Action on a Clipboard Item or an
Emoji makes it `lastSubject`; acting on anything else clears it. In memory only.
`reset()` stands it with the Query empty (`standingSubject`) after looking the
Clipboard Item up in history again — deleted or trimmed means none. It is not a
Result, so the Slab stays away and `SubjectCardView.subject` reads it from the
coordinator. Enter runs its default action, Tab opens its Actions and Shift+Tab
comes back to it; the first keystroke ends it standing.

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
- Tab → `advancePhase()` / Shift+Tab → `retreatPhase()`, both unconditional.
  **Shift+Tab does not arrive as `.tab`, and testing for it that way is why it did
  nothing at all for a while.** AppKit gives a back-tab its own control character
  — `NSText.h` spells them `NSTabCharacter = 0x0009` and
  `NSBackTabCharacter = 0x0019` — and SwiftUI passes it straight through, so
  `press.key` is U+0019 and a `press.key == .tab && press.modifiers.contains(.shift)`
  test is false for every Shift+Tab ever pressed. `KeyEquivalent` has no `.backTab`,
  so the scalar literal is the only spelling. Apple documents none of this and
  `KeyPress.characters` — "the characters generated by the pressed key as if no
  modifier key applies" — reads like a promise that the back-tab normalises back
  down to a tab, which is **wrong**: a probe logging both fields recorded
  `key=U+0019 characters=U+0019 modifiers=0x0002[shift]`, against `U+0009` in both
  with no modifiers for a plain Tab. The `.shift` test that remains is not
  redundant — U+0019 is also Ctrl+Y, which would otherwise retreat the Phase.
  Shift+Tab is the inverse of **Tab**, not of Ctrl+L: it is unconditional, so in
  Emoji Mode it leaves the grid rather than walking a cell left.
- Up/Down → `moveUp()` / `moveDown()`
- Left/Right → `moveLeft()` / `moveRight()`, which mean something only in a grid
- Escape → `handleEscape()`
- Cmd+Backspace → `deleteSelectedClipboardItem()` **first**, and only `retreatPhase()`
  when there was no Clipboard Item to delete. In Clipboard Mode it deletes the selected
  Clipboard Item from Clipboard History on the spot — Finder's Cmd+Delete habit, no
  confirmation — and the Panel, the Mode and the Query stay, with the row that took its
  place selected. Never a file. Shift+Tab is unaffected.
- Shift+Space → `triggerQuickLook()`
- Ctrl+E / Cmd+E → `toggleTextSubjectEdit()` — **any** text Subject, not just a
  Clipboard Item: OCR Text and a transform's output too. In Subject search it turns
  a non-empty Query into a text Subject; with an empty Query it edits only a text
  Subject already there, such as a standing Last Subject
- Ctrl+J/K → `moveDown()` / `moveUp()`
- Ctrl+H/L → `moveLeft()` / `moveRight()` **first**, and only `retreatPhase()` /
  `advancePhase()` when the horizontal move meant nothing. Routing them straight to
  the Phase took Ctrl+H and Ctrl+L out of Emoji Mode. Both spellings of a
  Control-modified key are accepted, via `ControlKey.letter`.

### View Cards
- **SubjectCardView** — shows app icon/name (a file's thumbnail once it lands), text
  preview, emoji glyph, or clipboard content, plus the corner chips
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

The Slab is **sized to its content**, up to `PanelLayout.maxResultsHeight`: ten
matching Emoji make a Slab two grid rows tall, and "No results" plus the Query bar
makes the shortest one there is (`PanelLayout.minResultsHeight`). Growing and
shrinking is the same `Motion.resize`, applied to the Results area's own frame with
`hardCut()` on the content inside it, so the surface springs while the cells cut.
`hitRegions.results` follows because the layout *reports* the Slab's frame — the
space the Panel reserved and the Slab did not use has to dismiss on a click.

### ClipboardHistory / PasteboardWatcher — clipboard capture
Polls `NSPasteboard.general` every 0.5s. Stores up to 100 items as JSON in Application
Support. Images saved as PNG files in `codiclens/images/`. Text previews for Quick Look
in `codiclens/previews/`. The pasteboard is only ever read on the main thread; the
PNG re-encode goes through `ImageReencoder`, off-main in the app and inline in tests.
A change carrying `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType`
(nspasteboard.org; what password managers mark a copied secret with) is not recorded at
all — no text, image or file.

**A Clipboard Item is a snapshot**: the text or the pixels at copy time. `previewURL`
for an image returns the **stored PNG**, never the original file — it used to prefer the
original when it still existed, which had Quick Look showing one file while Paste and
Open in Preview used another. `originalFilePath` is still stored and is now only a
display name; nothing fetches content through it, and there is no re-sync from the
original. Edits saved in Preview, and Rotate, land on the stored PNG, so Paste follows
them. See `docs/adr/0010-a-clipboard-item-is-a-snapshot.md`.

### QuickLookHelper — QLPreviewPanel bridge
Data source and delegate for system Quick Look. Handles keyboard events (j/k navigation, Shift+Space dismiss). Reports dismissal via `onDismiss` callback.

**A third-party `QLPreviewPanel` toolbar is close, fullscreen, title, Share and "Open with
Preview" — that is the whole list**, verified on macOS 26 by screenshotting a throwaway
app. Finder additionally shows Markup and Rotate because those are Finder **Quick Actions**
(Action extensions); there is no public API to host them here and private API was rejected.
Do not try to add them. The toolbar is Apple's and we add no keys inside the panel beyond
the navigation ones above. An image Subject gets Rotate and Open in Preview from the Panel
instead — `docs/adr/0011-image-edits-rotate-in-process-everything-else-is-preview.md`.

### Settings — General and Sources
`SettingsView` is two tabs. **General** is appearance, Emoji, the App Index refresh and
the Acknowledgements sheet, which shows every bundled licence (`emoji-data-license.txt`,
`digup-license.txt`; both are resources through the synchronised group). **Sources**
(`SourcesSettingsView`) lists every Source (`CONTEXT.md`) with one switch and two counts,
indexed and total, and nothing else: there is no priority between Sources. Folders are added
with the open panel and removed with the row's "−" or its context menu, without a
confirmation; removing one drops its File Index rows, never files. `SourcesPage` builds the
rows from `SourceStore` and closures for counts and reading state, so `SourcesPageTests`
runs it on its own `UserDefaults` suite. A row being read shows the Loading Ring with
"Reading" beside it, never a `ProgressView`.

Under Folders, **Skip** is what the File Index leaves out inside the folder Sources, all
user-set and kept by `SourceStore` beside the Sources: a checkbox per
`FileIndexRules.SkipGroup` (on = skipped; Caches, node_modules and build output, App bundles
and packages on by default; Hidden, Repos, .env files, Keys and certificates off, because the
user wants to find those) and a list of `SkipPattern`s. `.git` and bare-repo internals belong
to the bundles group, so a repo is indexed and its `.git` is not; `.DS_Store` is a cache.
Symlinks and iCloud files not downloaded are always out, not a switch. Patterns: no `/` is a
name glob anywhere (`*`, `?`), a trailing `/` is folders only, any other `/` matches the path
from the Source folder down (`**` = any folders). Nothing skips a Source itself. The writer is
handed `SourceStore.fileIndexRules`, a plain `Sendable` value, never the store. A change
re-applies through `FileIndexer.setRules`: rules that only skip *more* delete rows from the
index alone (no walk); anything that lets more in re-crawls the enabled roots, and the crawl
being a reconcile, that one pass also deletes what is newly skipped and leaves unchanged rows
alone. With Repos included the dev machine's three default Sources are ~290k rows, almost
all of it `~/Documents/Projects`: see `FileIndexTimingTests`.

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
| `SubjectSearchVM.swift` | Subject search: apps on the keystroke, the debounced list below them, and when "No results" is true |
| `SourceSearch.swift` | Ranking the list below the apps: File Results, Clipboard Items and Emoji on one scale, off the main actor |
| `ActionSearchVM.swift` | Context-sensitive action loading |
| `TargetSearchVM.swift` | Target list state; owns and cancels the file search |
| `FileTargetSearch.swift` | One cancellable Finder file search: File Index first, then `mdfind` lookups, ranking, icons |
| `Thumbnails.swift` | Quick Look thumbnails for files: async, cached per file version, and `ThumbnailImage`, the icon-then-thumbnail view |
| `ClipboardHistory.swift` / `PasteboardWatcher.swift` | Clipboard storage, and the pasteboard poller that feeds it |
| `ClipboardSearchVM.swift` | Clipboard search/filter |
| `QuickLookHelper.swift` | QLPreviewPanel data source/delegate |
| `Subject.swift` | Subject model (app/file/folder/text/builtIn) |
| `PathSubject.swift` | A Query beginning `/` or `~`, and the one URL→Subject resolver |
| `OCR.swift` | The whole of the app's Vision use: URL → OCR Text |
| `ImageActions.swift` | QR PNG generation and atomic, orientation-normalizing image rotation |
| `EffectRunner.swift` | Executes system Effects; serializes image jobs and returns their answers |
| `SubjectAction.swift` | Action model, text transforms, action handlers |
| `FuzzyMatch.swift` | Fuzzy scoring (exact/prefix/substring/subsequence/levenshtein) |
| `Emoji.swift` | Emoji model, SkinTone, default-tone preference, glyph→NSImage rendering |
| `EmojiIndex.swift` | Bundled emoji dataset: lookup, grouping, skin-tone variants |
| `EmojiSearchVM.swift` | Emoji ranking, grid sections, grid keyboard model |
| `EmojiRecentsStore.swift` | Emoji Recents persistence (Application Support) |
| `EmojiGridView.swift` | Results Slab in grid Mode |
| `Style.swift` | Every radius, material and tint, including the Card's glass shape and the Emphasis constants. The only `colorScheme` branch, and Cards do not use it |
| `Motion.swift` | The three transition curves, the Loading Ring's spin, the Reduce Motion read, entrance/shake/hardCut |
| `LoadingRing.swift` | The app's own spinner, in place of a system `ProgressView` |
| `AppIndex.swift` | The app Index: background scan, atomic swap, lazy icons |
| `AppDirectoryWatcher.swift` | FSEvents watch over the application directories |
| `Source.swift` | `Source` and `SourceStore`: the Sources, their switches and the folder list, in `UserDefaults` |
| `FileIndex.swift` | The File Index: started at launch, `search` from any thread, counts and reading state for Settings |
| `FileIndexStore.swift` | The File Index's SQLite schema, writer and thread-safe reader (`FileHit`) |
| `FileIndexer.swift` | Crawling a folder Source and applying FSEvents changes to the index |
| `FileIndexWatcher.swift` | FSEvents watch over the folder Sources |
| `FileIndexRules.swift` | What the File Index leaves out, in one place for the crawl and FSEvents: the skip groups and patterns |
| `SQLite.swift` | A thin SQLite connection and statement wrapper |
| `SourcesPage.swift` | The Sources page's rows (switch, counts, reading state), its add/remove/switch controls, and the Skip switches and patterns |
| `SourcesSettingsView.swift` | The Sources tab in Settings, drawn from `SourcesPage` |

## Known issues

Real, unfixed, none urgent.

- **A one-letter Target search is still slow, and it is Spotlight.** `mdfind -name a
  -onlyin ~/Documents/` takes ~7s to return its *first* batch on the dev machine
  (Downloads ~0.7s, system-wide ~2.4s), so the line cap cannot help. The File Index
  now answers for the folder Sources first, so the list has rows at once and only
  the files outside the Sources wait for it; "Searching…" stays up until it lands.
  Cancellation means it only costs anything if the user stops typing at one letter.

- Signing teams are inconsistent. Both targets override `DEVELOPMENT_TEAM` to
  `L256GR2793`, while the project-level default is `HHNPP7C8GB`. Will bite on a clean
  checkout.
- **A Subject Card outside a Query Phase shows `selectedSubject`, not
  `subjectVM.results[selectedIndex]`.** `SubjectCardView.isQueryPhase` is the
  switch. The two values are only the same while the Query is still the question
  being asked; once a Subject has been *chosen* they diverge, and reading the
  results is how "Use as Subject" left Finder on the Card after promoting a file
  out of it. `retargetedText` solved the same bug for OCR Text and a transform's
  output and was `.text`-only, so a promoted file fell straight through it. The
  name is marked up against the Query only in a Query Phase, for the same reason:
  a chosen Subject's name is not what the Query matched.
- `SubjectCardView.textSubjectEditor` takes focus from a `.task`, which is the first
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
- **`glassEffect` does not rasterise deterministically under `ImageRenderer` in
  Debug.** Two renders of the same Card differ by up to Δ36 on most pixels, a dither;
  in Release the same pair is bit-identical. Any future pixel test has to average
  several renders (six brings the residual under Δ5) or run in Release.
- **Release-configuration tests fail and have nothing to do with the Panel.** Run
  with `-configuration Release SWIFT_ENABLE_TESTABILITY=YES` (Release lacks
  testability, so `@testable import` will not resolve without it), the
  `PasteboardWatcherTests` cases in `ClipboardHistoryTests.swift` abort the test
  host, which marks every suite scheduled after them failed at 0.000s. Every suite
  passes when run on its own, and the whole suite passes in Debug. The documented
  command is the Debug one.
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
