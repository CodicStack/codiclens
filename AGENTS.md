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
- **`Motion.swift` owns every curve, in two categories.** A **Transition** carries
  a change the user caused, and there are exactly three — `entrance`, `resize`,
  `snappy` — used only by the Panel appearing, the Panel dismissing and a surface
  resizing. Phase advances, Card content swaps and selection movement are
  instant *on purpose*: an animated highlight lags the keypress. A window frame
  change needs `Motion.resizeDuration` / `Motion.resizeTimingFunction`, because
  `NSAnimationContext` cannot take a SwiftUI `Animation`.
  **Decoration** is the second category — `beamSweep` and `ringSpin` — and it is a
  category rather than two more curves: the budget was never "three is the number",
  it was *do not animate information*. A decoration carries nothing learnable,
  delays nothing, is never given a threshold before it appears, and is **absent**
  under Reduce Motion rather than collapsed (it reads `Motion.isReduced` directly,
  because `collapsed(_:)` makes a cross-fade and a loop has nothing to cross-fade
  to). The next animation that "just needs to show that something is happening" is
  a transition wearing decoration's clothes and goes through the three curves. See
  `docs/adr/0003-motion-budget.md`.
  **`Motion.swift` also owns the app's only two AppKit accessibility reads, and
  they are independent.** `isReduced` is Reduce Motion plus the app's own
  animations preference, and its answer is that a decoration is absent.
  `isTransparencyReduced` is Reduce Transparency, which is a claim about
  legibility rather than about movement — Apple asks for opaque content over
  semi-transparent, and a blur is semi-transparent — and its answer is that the
  Border Beam **drops its glow layer and keeps sweeping**. Do not fold the second
  into the first or give `isReduced` a second meaning: with Reduce Motion on there
  is no beam at all, with only Reduce Transparency on there is a beam with no halo,
  and neither switch implies the other. `Style.beamDrawsGlow` consults
  `Motion.isTransparencyReduced` rather than reading `NSWorkspace` itself, so both
  reads stay in the one file. The layer goes **whole**, not un-blurred — that was
  the answer while the beam was one layer, and un-blurring a `beamGlowWidth`-wide
  band is a flat 10pt bar travelling the rim rather than a quieter halo.
- **The Border Beam belongs to a *Card* and means nothing.** It sweeps around
  a Card that becomes about something new — `cardBeam(identity:)` on all three,
  applied *between* `.cardSurface(...)` and `.padding(Style.cardInset)`, because
  the padding sits outside the surface and a beam applied after it draws on the
  wrong bounds. `CardBeam` is the policy, `borderBeam(trigger:)` the primitive;
  keep them apart. It is **not** tied to OCR, to `isOCRInFlight`, to searching, or
  to any in-flight state; that misreading is the way this feature gets broken —
  OCR Text sweeps the Subject Card because the *Subject was replaced*, and nothing
  in `BorderBeam.swift` reads an in-flight flag.
  **The trigger is a pure function of coordinator state — `CardBeamIdentity` —
  and its hard rule is that a moving *selection* must never change a token.**
  Arrowing through Results, re-ranking on a keystroke, and `mdfind` filling in
  Targets all have to leave the tokens alone, or the Panel strobes; `AGENTS.md`
  and ADR 0003 both say selection movement is instant on purpose.
  `CardBeamIdentityTests` has eight negative cases pinning that, and they are the
  half of the suite that matters. One trap in particular: `moveUp`/`moveDown`
  **clear** `selectedSubject` while the Clipboard is browsed, so a token that read
  it in a browsing Phase would sweep on the first arrow key after Enter —
  `previewsASelection` is the gate that stops it.
  A token cannot tell an arrival from a departure, so `ActionCard.holdsKeyboard`
  changes on the way out too: Tab from Action to Target sweeps both Cards. That is
  the one unasked-for sweep here, and it is the price of the trigger being pure —
  the alternative silently loses the Shift+Tab-back sweep.
  `CardBeam` keeps an unconditional `onAppear` bump as well as `onChange`, because
  `CardContainerView` inserts the Action and Target Cards on `cardCount`, so a
  fresh view's `@State` starts at 0 and its `onChange` never fires. That
  `onAppear` — not the old focus edge — is why the Action Card was the only one
  ever seen sweeping.
  **It was twice wrong before this, and neither was catchable by reading.** It was
  built on the Slab and triggered by the Slab arriving, which fires once per
  summon on the first keystroke and so was invisible in use; widening the trigger
  left the surface wrong. Do not move it back to the Slab, and do not narrow the
  trigger to arrival. A Card focused across a dismiss-and-resummon sees no
  false→true edge and no `onAppear`, so it does not sweep on that summon — known,
  documented on `CardBeam`, not a bug to fix twice.
  `Style.beamSeamOffset` is **exact** (0.6192), because every Card is one
  size — it was a compromise across the Slab's variable proportions. Probe it, do
  not compute it: the analytic `(1.5h + w) / 2(w + h)` happens to land within
  0.00025 at radius 22 and that is luck, not a method — it also landed within
  0.0002 at the *previous* surface size, and neither agreement was predictable.
  It is a function of the **drawn surface**, not of the Card's cell: it did not
  move when `cardInset` went 12 → 24, because `PanelLayout.cardWidth` and
  `cardHeight` went up by the same amount and the surface stayed 236 × 216.
  **Re-probe it whenever `cardRadius` moves, or whenever a change to `cardWidth`,
  `cardHeight` or `cardInset` moves `cardWidth - cardInset * 2` or
  `cardHeight - cardInset * 2`** — by sweeping `trim` and taking the fraction whose
  point is nearest the rect's top-left; at 236 × 216 that is 0.619221, landing at
  (6.41, 6.41), the 45° midpoint of the corner's own curve. Read the *first* point
  of `trimmedPath(from: f, to: f + ε)` — `currentPoint` on
  `trimmedPath(from: 0, to: f)` gives the sub-path's end and is `nil` at f = 0.
  It shares one drawing primitive with the
  Loading Ring — an animated `trim` along a stroked path — and nothing else.
  Two things it must not become: a rotating **conic gradient**, which sweeps at a
  constant *angular* rate and so races a wide rectangle's long edges and crawls its
  corners; and a **stroke gradient**, which does not follow a path. `trim` *is*
  uniform in path length — verified: `cardShape`'s path starts at the right edge's
  vertical midpoint and runs clockwise, which is why the top-left corner falls a
  little past 0.5.
- **The beam is a *comet* in TWO layers: a crisp 1pt core inside a soft glow, both
  masked outward.** This is the shape of the thing and the part most likely to be
  "simplified" back into a bug. **One layer cannot do it**, because a slice has one
  blur radius, so a crisp line and a bloom around it are two strokes or they are
  nothing. It shipped as one layer once, with the core's blur "exactly 0 at the
  head, because the crisp leading edge against a dissolving tail is the entire
  contrast the comet lives on" — a sentence that reads like taste and was
  architecture. Measured on the real modifier, that version put **zero** light more
  than 1pt outside the rim at the head. The head had no halo; it was a line. Do not
  merge the layers.
  **The glow is not the "fixed lamp" arriving by the back door, and the lamp is
  still declined.** The reference material — a Card whose whole rim carries a soft
  permanent light — *is* a static gradient rim, and satisfying it by drawing one has
  been explicitly turned down ("comet only, no fixed lamp"). The glow is lit only
  while a sweep runs, it travels, and it is gone in 0.55s. A still frame cannot tell
  the two apart, which is exactly why this keeps coming up.
  **Core:** `Style.beamWidth` 1 (the *visible* width), `beamStrokeWidth` doubled
  because a `.stroke` is centred on its path and the mask keeps the outer half; a
  2.0pt stroke measures exactly 1.00pt outward at full alpha — probed, on the
  assumption the mask's antialiasing would eat some of it; it does not, because the
  mask edge and the stroke's inner edge are the same curve. Blur ramps 0 →
  `beamCoreTailBlur` (6), and 0 at the head is still right *now that there is a
  glow under it*.
  **Glow:** `beamGlowWidth` 10 before blurring, `beamGlowStrokeWidth` doubled for
  the same mask, blur ramping `beamGlowHeadBlur` (10) **under the head** *up* to
  `beamGlowTailBlur` (20) at the tail, and **never 0 anywhere the beam is lit**.
  The band is wide on purpose: brightness at the rim comes from the band's width
  and reach comes from the radius, so a hairline source cannot buy brightness with
  radius — turning up the old 1pt line's blur made it wider *and fainter*.
  Both layers are `Style.beamSegments` (20) equal slices of path length, one slice
  list drawn twice, one `BorderBeam.outward` mask over both, because there is **no
  API that makes a gradient or a blur follow a path's arc length** and per-slice
  blur out of the one arc-length-uniform primitive (`trim`) is the only way to vary
  one. `Style.beamFalloff` stays **deleted**: blur already dims by spreading the
  same alpha over more pixels, and stacking a computed opacity ramp on top is the
  double-multiplication that exponent existed to undo — it once left 40pt of an
  intended 336pt on screen. The head-to-tail *colour mix* is not that ramp; two
  named colours with different alphas is what `BeamSlice` has always done.
  Round caps bulge half a line width past each slice's trim range, so nineteen
  joints composite twice and the beam renders as a row of beads: the caps stay
  `.butt`, and it matters twenty times more on the glow.
  **The ceiling on the glow is the gutter, `cardInset * 2`** — it must not reach a
  neighbouring Card's rim. Measured reach is **34pt** against a 48pt gutter, which
  is why `cardInset` went 12 → 24. `PanelLayout.cardWidth`/`cardHeight` went
  260 → **284** / 240 → **264** *with* it, so the drawn surface is still 236 × 216:
  the previous inset bump took its growth out of the surface, which cost Card
  content, and this one takes it out of the Panel's declared size, which costs
  nothing. The Panel is still fixed and still never resizes. `PanelLayout.margin`
  did **not** move and was checked rather than assumed — every rim has more than
  34pt of clearance, the tightest being 36pt from the bottom rim to the Results
  Slab.
  **Normal compositing, never additive.** `.plusLighter` was measured and rejected:
  over a white ground it saturates every covered pixel, so the profile at the head
  and at three points down the tail come back *identical* and the falloff stops
  existing. In light appearance it has nowhere to go at all — nothing is brighter
  than a light wallpaper.
  `Motion.beamSweep` is 0.55s and stays `easeOut` — the visible *end* of a sweep is
  the tail draining through the seam, and easeOut spends its last frames there. It
  did **not** change for the glow: the glow got wider outward, not longer along the
  rim, and the lit segment is still `beamTailFraction` of the same perimeter.
  **All of it was found by rasterising with `ImageRenderer`**, because
  `BorderBeamTests` pins the trim geometry and passed the whole time the beam was
  invisible. `BorderBeamRenderTests` is the pixel-level counterpart and the only
  test here that looks at pixels. It pads what it rasterises by
  `cardInset + beamGlowTailBlur` (the beam is outside the Card's bounds and
  `ImageRenderer` renders a view at its own size, so an unpadded render crops the
  effect: 327 lit pixels against 1,039 back when the halo reached 11.5pt), it
  asserts **zero beam pixels inside the rim**, and it asserts **the head has a halo
  and a crisp core** — floors on the alpha 1, 4, 8 and 16 points out at the head's
  own phase, which on the shipped one-layer version were 0, 0, 0, 0. That third
  assertion is the one worth having: it is the only one that would have caught what
  the user actually rejected.
  **`BorderBeamRenderTests` passing is not the same as the beam reading right.**
  A render can prove light is on screen and cannot say whether there is enough of
  it. That is why the numbers below are here rather than only in a test.
  Two things it must not become: a rotating **conic gradient** and a **stroke
  gradient** — see the bullet above for why.
- **The beam's light-appearance colours are saturated, not pale, and that is the
  fix for a real measured inversion.** Light's `beamHead` was (0.62, 0.78, 1.00)
  and measured Δ43/765 of luminance against a white Card while `beamTail` measured
  Δ127 — the head a third the contrast of the tail it was supposed to lead. It is
  now **(0.20, 0.45, 1.00)** and measures Δ207/442 of perceptual distance on white,
  Δ149 on mid-grey and Δ250 on near-black. **The lever was saturation, not
  lightness**, and the previous pass's conclusion that "no single opaque colour
  reads against both a white and a mid-grey backdrop" was true of every candidate
  it tried and false of the space: it was varying lightness, which is the axis the
  two grounds disagree on. A mid-luminance saturated blue is 247 units from white
  and 255 from black. On a light ground the beam's luminance delta is **negative** —
  it darkens — and that is the only option available, because nothing is brighter
  than a white wallpaper. Light appearance's glow is a coloured halo, not a bright
  one.
- **The Card's own black shadow does not eat the glow, and this was measured before
  being left alone.** `Style.shadowRadius` 16 of black falloff sits in exactly the
  band the glow lives in, which looks like a problem and is not. Head contrast on a
  white ground: Δ239 with no shadow, Δ207 at the shipping 0.20, Δ174 at 0.44 — so
  the shadow costs about 13% there. Everywhere else it *helps*: on mid-grey it goes
  the other way (Δ144 → Δ149 → Δ158), on near-black it is noise, and dark
  appearance's white head over a *light* backdrop measures Δ1 with no shadow
  against Δ91 with it, which makes the shadow load-bearing rather than harmful.
  Do not suppress a Card's shadow while its beam sweeps; the numbers do not support
  it and it would couple `Style` to a decoration's state.
- **The Loading Ring is not a progress indicator.** A constant-length 270° arc that
  turns, in both of the Panel's waiting states. Neither Vision nor `mdfind` reports
  progress, so a ring that *fills* would be claiming something the app cannot back.
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
  message must not be delayed. Subject search matches the app Index, and until
  the first scan lands the Slab shows the Query bar **alone** — no message row,
  which is the shortest Slab there is (`PanelLayout.queryOnlyResultsHeight`).
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
- `onOCRText` → `coordinator.receiveOCRText(_:)` — the OCR Text coming back the
  other way. The only callback that answers the coordinator rather than doing
  something to the window, and the reason `CommandCoordinator` neither imports
  Vision nor `await`s. See `docs/adr/0007-async-action-behind-the-effect-seam.md`.

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

A file becomes a Subject two ways, and neither is a file browser — see
`docs/adr/0008-a-file-can-be-a-subject.md`. A **Path Subject** is a Query
beginning `/` or `~`, resolved by `PathSubject` to exactly one file or folder;
those two prefixes cannot collide with an app name, so none of the Index's
gates move for one. **Use as Subject** is a non-Final Action that promotes a
file-or-app Target into the Subject and lands back on `.pickingAction`. Files
are deliberately *not* ranked alongside apps in Subject search.

OCR is the one Action that takes time. It returns `[.ocr(url)]` and **no
`.hide`** — the OCR Text lands *in* the Panel — and `EffectRunner` awaits
Vision and answers through `onOCRText`. `isOCRInFlight` gates a second Enter
and is what the Slab's "Reading text…" row reads.

Text mode: activates only when fuzzy search returns zero app matches
(result-dependent, not input-dependent) — **and only once the Index has
answered**. `SubjectSearchVM.isIndexReady` is that gate. Before the first scan
lands there are zero matches because nothing was searched, and standing a text
Subject in for that turned every character of a cold start into prose.

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
- Shift+Space → `triggerQuickLook()`
- Ctrl+E / Cmd+E → `toggleTextSubjectEdit()` — **any** text Subject, not just a
  Clipboard Item: OCR Text and a transform's output too
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
| `PathSubject.swift` | A Query beginning `/` or `~`, and the one URL→Subject resolver |
| `OCR.swift` | The whole of the app's Vision use: URL → OCR Text |
| `SubjectAction.swift` | Action model, text transforms, action handlers |
| `FuzzyMatch.swift` | Fuzzy scoring (exact/prefix/substring/subsequence/levenshtein) |
| `Emoji.swift` | Emoji model, SkinTone, default-tone preference, glyph→NSImage rendering |
| `EmojiIndex.swift` | Bundled emoji dataset: lookup, grouping, skin-tone variants |
| `EmojiSearchVM.swift` | Emoji ranking, grid sections, grid keyboard model |
| `EmojiRecentsStore.swift` | Emoji Recents persistence (Application Support) |
| `EmojiGridView.swift` | Results Slab in grid Mode |
| `Style.swift` | Every radius, material, tint and rim, and both of the Border Beam's layers. The only `colorScheme` branch |
| `Motion.swift` | The three transition curves, the two decorations, the Reduce Motion and Reduce Transparency reads, entrance/shake/hardCut |
| `BorderBeam.swift` | A Card's one-lap comet: over-travel geometry, slicing, the two layers, the outward mask, `CardBeam`'s identity policy |
| `LoadingRing.swift` | The app's own spinner, in place of a system `ProgressView` |
| `AppIndex.swift` | The app Index: background scan, atomic swap, lazy icons |
| `AppDirectoryWatcher.swift` | FSEvents watch over the application directories |

## Known issues

Real, unfixed, none urgent.

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
- **The Border Beam costs 1.4 ms per frame per Card in Release and 2.6 ms
  unoptimised**, up from 1.0 / 2.3 when the glow layer was absent — measured with
  `ImageRenderer` over a 34-frame sweep, so the glow's own share is about 0.4 ms
  and it is the wider radii rather than the extra slices. Tab sweeps two Cards at
  once, which is the worst realistic case and still inside a 16.6 ms frame.
  `ImageRenderer` is a CPU rasteriser with a bitmap allocation per frame, so
  on-screen compositing should be cheaper. The remedy if it is ever needed is
  measured and deliberately not applied: `Style.beamSegments` 20 → 12 costs
  1.11 ms instead of 1.43 and coarsens the falloff without breaking it.
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
