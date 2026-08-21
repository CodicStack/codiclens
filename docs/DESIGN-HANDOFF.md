# Design handoff — read this before touching the visual layer

The visual overhaul on `feat/emoji-index-glass-motion` produced a bad result. This
file exists so the next session does not repeat it, and does not start from the
wrong theory about why.

**The design is now yours to own outright.** Nothing in the current appearance is
defended. What follows is what is true, what is committed, and where the traps
are.

---

## First: the theory you may have been handed is wrong

> "I have a suspicion that it was the move to a single panel instead of our old
> setup?"

**No. The single-Panel restructure never landed.** Verify it yourself:

```
grep -n "cardPanel = \|resultsPanel = " codiclens/PanelController.swift
```

`PanelController` still creates **two** `FloatingPanel`s and still hand-positions
the second below the first, exactly as it did before this branch. The agent
assigned to that work died to an infrastructure fault before it wrote a line of
`PanelView.swift`.

Everything ugly in the screenshots came from `Style.swift` and the card views —
the material layer, not the window structure. That matters, because "revert the
single-Panel work" is not an available fix and would not help.

---

## The two artefacts, named

Both are fixed in the current tree. They are recorded because they are easy to
reintroduce and hard to diagnose from a screenshot.

### 1. The ragged, hand-drawn-looking wavy outline

`FloatingPanel` had `hasShadow = true`. AppKit derives a window shadow from the
content's **alpha mask**. When the content is transparent glass whose edges are
soft — which is what a SwiftUI `.shadow()` on a full-bleed view produces — that
derivation traces a jagged wavy contour around the content, and often a ghost
second outline offset from the first.

`hasShadow` is now `false` and must stay false. Separation is the content's job.
This is also what ADR-0001 says, for the same reason.

### 2. The hard dark band down the right and bottom edges

A `.shadow()` applied to a view that **fills its window** is clipped by the
window bounds. Instead of a falloff you get a hard band along two edges, which
reads as a duplicated offset rectangle.

There are only two honest fixes, and the second is the real one:

- Don't cast shadows from full-bleed views (what the tree does now — no shadows
  at all).
- **Size the Panel larger than its content**, so every Slab and Card has room to
  cast a real shadow inside the window. This requires the single-Panel
  restructure, or at minimum padding the existing two Panels.

Until a Panel has margin, do not add a shadow back. It will look broken again.

### A related trap: stroke *after* clip, not before

`.overlay { shape.strokeBorder(...) }` followed by `.clipShape(shape)` cuts the
hairline in half and aliases along the curve. Stroke after clipping. `Style.swift`
now does.

---

## What the user actually asked for, in their words

Collected across the session, so intent is not lost in paraphrase:

- **"it needs to be glass panels that can morph out of each other and stuff like
  that."** This is the north star. Not static surfaces — surfaces that visibly
  come out of one another. `GlassEffectContainer` + `glassEffectID` is the
  intended mechanism and is available unconditionally on the 26.4 target. It was
  listed as optional in the old brief. Treat it as central instead.
- **"can you see how unified that is?"** — about the reference. Unity is the
  quality being asked for. The current build reads as unrelated boxes.
- **"I don't think we need borders. Maybe on the card. Not on the slab."**
  Implemented: no rim on a Slab, a faint rim on a Card.
- **"We don't need that accent colour blue."** The palette has no accent colour
  at all. Focus and selection are brightness and rim weight.
- **"The card below could have a lower border radius."** Results Slab is 18, a
  Card is 22.
- **"The original design we had before was way better with none of this."** Worth
  taking literally. `git show 6bce579:codiclens/AppTheme.swift` is the old
  `ThemedGlass`, and the card views at that commit are the "before". Starting
  from that and moving in small steps may beat continuing from here.

### An unresolved contradiction you must settle with the user

The user said **"we should not have the outer box"** — and later pointed at a
reference screenshot that *has* an enclosing container around the two Cards and
praised it as unified.

Both instructions are in the transcript and they conflict. The current tree
follows the first: no Card Slab, Cards are standalone surfaces. **Ask before
building either way.** This also decides whether ADR-0001 stands.

---

## State of the code

Branch `feat/emoji-index-glass-motion`. Build green, `** TEST SUCCEEDED **`, 168
unit tests.

### Committed this session

| Commit | What |
|---|---|
| `44bdef5` | ⌃⌘Space as a plain hotkey; private-API takeover deleted; Accessibility prompt moved off the launch path; explicit `applicationWillTerminate` teardown; `AppIndex.current` static replaced by `CommandCoordinator(index:)`; template UI tests deleted |
| `3e717af` | `Style.swift` token layer; emoji Subject Card; `codiclensUITests` target removed |
| `d0701dc`, `075424f` | Visual corrections on user feedback — accent removed, radii, Cards as surfaces |
| `724a5a9` | `Motion.swift` |

### The visual layer as it stands

- **`codiclens/Style.swift`** — every radius, material, tint and rim. The only
  file that branches on `colorScheme`. Three tiers: `slabSurface()`,
  `cardSurface(focused:writing:)`, `resultSurface(selected:)`, plus
  `chipSurface()`. Radii: Slab 18, Card 22, Result 10, `cardIcon` 64.
  **This file is the right idea even though its current values are not.** Keep
  the one-place-for-everything property; change the values freely.
- **`codiclens/Motion.swift`** — three curves and nothing else: `entrance`,
  `resize`, `snappy`, collapsed to a cross-fade in one place by Reduce Motion or
  the Settings toggle. The measured show (opacity in ~33ms, blur clearing ~85ms,
  scale 0.90 → 1.04 → 1.00) is shaped as three functions of one spring-driven
  progress value. Also `panelEntrance(visible:)`, `shake(trigger:)`, `hardCut()`.
  **`panelEntrance` and `shake` are written but not wired to anything.** Wiring
  them needs the Panel work.

### Still not done, from the original four-feature push

- **The single-Panel restructure.** ADR-0001. Not started. Revisit the ADR itself
  first — the "outer box" contradiction above may change it.
- **`asyncAfter(0.25)` in `PanelController.updateResultsVisibility()`.** A timing
  hack, violates `AGENTS.md`, still there. It exists *only* because there are two
  windows; it should die with the second window and must not be replaced by
  another delay.
- **Pinned display-only Query field** at the bottom of the Results Slab. The
  reference has one and it resolves a real ambiguity: the Subject Card shows a
  matched app name, not what you typed.
- **Shake on no-match.** `Motion.shake` exists; nothing calls it. Today a
  no-match silently becomes a text Subject.
- **A `⌘⏎`-style hint chip** bottom-trailing inside a Card. `chipSurface()`
  exists.
- **Results Slab animating in and out** with `resize`, always present in emoji
  Mode.

---

## Known, unfixed, non-visual

Found while diagnosing; none is urgent, all are real.

- **`PasteboardWatcher.record()`** decodes and PNG-re-encodes image data
  **synchronously on the main thread**. Copy a large screenshot and the UI
  stalls. Pre-existing.
- **`EmojiIndex.shared`** parses a 226 KB JSON on the main thread at launch,
  forced by a default argument in `CommandCoordinator.init`.
- **`EffectRunner.simulateTyping`** uses `usleep(10_000)` per character. Off the
  main thread, so harmless, but it violates `AGENTS.md`'s no-timing-hacks rule.
- **`SubjectCardView.clipboardEditor`** has a `DispatchQueue.main.asyncAfter(0.1)`
  focus hack. Same rule.
- **Signing teams are inconsistent** — the app and unit tests are `L256GR2793`.
  Will bite on a clean checkout.

## The "app won't terminate" claim from the previous handoff

Treat as **unsubstantiated**. The only evidence was a UI test that asserted
nothing, launched the app five times per run under a debugger, and raised an
Accessibility dialog on every launch. A `codiclens-*.ips` in
`~/Library/Logs/DiagnosticReports` was investigated and is a **debugger
breakpoint trap during process exit** — `brk #0` (LLDB's opcode, not Swift's
`brk #1`) patched into `start_wqthread`, no app frames in any thread, no main
thread present. It is not evidence of a hang. No hang artefact exists anywhere on
the machine.

Explicit teardown was added anyway because it is correct on its own merits. If a
hang is ever seen again, capture `sample <pid> 10` or `spindump` **while it is
hung**; `ps -o %cpu` near 100% means a spin, near 0% means a block.

---

## Rules that are not negotiable

From `AGENTS.md` and the ADRs. These survived the redesign and should survive the
next one.

1. **No timing hacks.** No `asyncAfter`, `sleep`, `usleep` as a fix. Event-driven
   or sequential.
2. **`.nonactivatingPanel` must hold.** It is what keeps the previously-frontmost
   app frontmost, which is what makes CGEvent paste simulation land in the right
   place. Breaking it breaks pasting.
3. **Only three curves exist**, and only the Panel appearing, the Panel
   dismissing, and a surface resizing use them. Phase advances, Card content
   swaps and selection movement are instant *on purpose* — an animated highlight
   lags the keypress. This is ADR-0003 and it is a real constraint, not polish.
4. **One place for materials.** No view outside `Style.swift` holds a radius, a
   colour, a shadow, or a `colorScheme` branch.
5. **Both appearances must be excellent.** The theme picker stays. Light and dark
   need asymmetric treatment — light washes out without a stronger material,
   dark leans on separation. Symmetric values are what failed the first time.
6. **Emoji glyphs go through `EmojiRenderer`.** Apple Color Emoji is a bitmap
   font with strikes at 20/26/32/40/48px; an off-strike point size resamples and
   reads visibly soft. The largest strike is 48, so a glyph slot much bigger than
   64pt will look soft unless a larger strike is added to `Emoji.swift`.
7. **Deployment target is 26.4.** Liquid Glass is unconditional. No `#available`.

## One API note, already checked

`ConcentricRectangle` exists in the 26.4 SDK and would derive nested corner radii
from an enclosing `containerShape` automatically. It is a `Shape` but **not** an
`InsettableShape`, so it has no `strokeBorder`. If a tier needs a hairline rim,
either stroke a `RoundedRectangle` or use `.stroke` and accept the centred line.
Verified by compiling against the SDK, not from memory.
