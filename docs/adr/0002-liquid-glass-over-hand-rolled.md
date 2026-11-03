---
status: accepted
---

# Liquid Glass, not a hand-rolled blur

Slab and Card materials use the macOS 26 Liquid Glass API (`.glassEffect`, `GlassEffectContainer`). Deployment target is 26.4, so no `#available` gating is needed anywhere.

This is worth recording because our visual reference, Tuna, does **not** use Liquid Glass — static inspection of its shipping binary shows `NSVisualEffectView` plus an animatable `CALayer` `CIGaussianBlur.inputRadius`, with zero Liquid Glass symbols. Someone comparing the two apps will notice the difference and may assume we made a mistake.

We didn't. Tuna's deployment target is macOS 15, so Liquid Glass was not available to them; the hand-rolled blur is a compatibility constraint we don't share. What we take from Tuna is its *geometry, its tint-as-selection signal, and its restraint* — not its material implementation.

## Why the minimum is 26.4, not 26.0

Every glass API we use arrived in macOS 26.0, and the app builds clean with a 26.0 deployment target. We keep 26.4 anyway, for one OS bug. macOS 26.4 fixed FB21375029: a non-opaque window hosting glass stopped updating the backdrop behind the glass while the window was inactive. The Panel is exactly that window: a borderless, non-opaque, `.nonactivatingPanel` `NSPanel` full of SwiftUI glass, and Codiclens is never the active app while it is up. On 26.0 to 26.3 the glass would likely keep refracting a stale picture of what was behind it.

The fix lives in the OS, so building against the 26.4 SDK doesn't bring it to older systems. The only workaround is to make the app active, which breaks the non-activating contract and the synthesised ⌘V into the app underneath. Few people stay on 26.0 to 26.3, so the cost of excluding them is small. Revisit only if users on those versions ask; the check to run first is in the minimum macOS research on issue #3.

## Consequences

- Material tokens live in one place (`Style.swift`). Before this decision the same `.ultraThinMaterial` + opacity-overlay recipe was copy-pasted across four files with drifting corner radii.
- The old dark-mode treatment (`Color.black.opacity(0.92)` over a material) is gone. It was effectively opaque and was the reason the app read as "solid, not glass."
- Both light and dark appearances are supported; the theme picker stays. Light mode gets a stronger material and a defined rim, because symmetric treatment washes out on light wallpapers.
