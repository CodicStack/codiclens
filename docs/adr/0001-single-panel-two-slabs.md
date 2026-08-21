---
status: accepted
---

# One Panel drawing two Slabs

Codiclens looks like two floating windows — a Card Slab with a gap beneath it and a Results Slab below. It is implemented as a **single borderless, transparent, non-activating `NSPanel`** sized once to its maximum extent, with both Slabs drawn as SwiftUI views inside it and genuine empty space between them.

We previously ran two real `NSPanel`s. That gave us two animation clocks that visibly disagreed during resize, forced a `DispatchQueue.main.asyncAfter(0.25)` before showing the results window, and made the positioning of the second window jitter. One window means one clock.

## Considered options

- **Two `NSPanel`s** (the previous design, and what Tuna — our visual reference — does). Lower risk, no refactor. Rejected: it keeps both the timing hack and the two-clock problem, and Tuna only gets away with it because it animates almost nothing.
- **One merged Slab**, Spotlight/Raycast style. Rejected outright on taste — the two-surface look is the design.

## Consequences

- `hasShadow` must be `false` on the Panel; each Slab draws its own SwiftUI shadow. AppKit deriving a shadow from transparent content is slow and artifact-prone.
- The empty gap belongs to the Panel, so hit-testing must treat clicks there as "outside" — the existing click-outside-to-dismiss monitor depends on it.
- The Panel never resizes. Slabs animate their own size inside a fixed window.
- Reverting to two windows is a real refactor, not a flag. Accepted deliberately: what we expect to want to tune is the *feel*, and that lives in `Motion.swift`, not in the window count.
