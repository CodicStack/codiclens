---
status: accepted
---

# One Panel drawing two Slabs

Codiclens looks like two floating windows — a Card Slab with a gap beneath it and a Results Slab below. It is implemented as a **single borderless, transparent, non-activating `NSPanel`** sized once to its maximum extent, with both Slabs drawn as SwiftUI views inside it and genuine empty space between them.

We previously ran two real `NSPanel`s. That gave us two animation clocks that visibly disagreed during resize, forced a `DispatchQueue.main.asyncAfter(0.25)` before showing the results window, and made the positioning of the second window jitter. One window means one clock.

## Considered options

- **Two `NSPanel`s** (the previous design, and what Tuna — our visual reference — does). Lower risk, no refactor. Rejected: it keeps both the timing hack and the two-clock problem, and Tuna only gets away with it because it animates almost nothing.
- **One merged Slab**, Spotlight/Raycast style. Rejected outright on taste — the two-surface look is the design.

## Update — implemented, and there is only one Slab

This is now the shipping design. Two details came out differently from the wording above:

- **There is no Card Slab.** The Cards float directly over the desktop in a row, each
  its own glass surface with its own rim and shadow. "We should not have the outer
  box." The Results Slab is the only Slab. (Since ADR 0009 the rim and that
  hand-drawn shadow are gone; the native glass supplies both.)
- **The Panel's fixed extent includes a margin on all four sides** —
  `PanelLayout.margin`, sized for the entrance animation's 1.04 overshoot plus a
  shadow beyond it. Without it a `.shadow()` is clipped into a hard band by the window
  bounds and a scaling entrance clips the same way, which is why both were disabled
  before this work.

## Consequences

- `hasShadow` must be `false` on the Panel; the Results Slab draws its own SwiftUI shadow, and a Card's native glass casts its own (see `docs/adr/0009-cards-are-bare-glass.md` — a Card never gets a hand-written shadow). AppKit deriving a shadow from transparent content is slow and artifact-prone.
- The empty gap belongs to the Panel, so hit-testing must treat clicks there as "outside" — the existing click-outside-to-dismiss monitor depends on it.
- The Panel never resizes. Slabs animate their own size inside a fixed window.
- Reverting to two windows is a real refactor, not a flag. Accepted deliberately: what we expect to want to tune is the *feel*, and that lives in `Motion.swift`, not in the window count.
