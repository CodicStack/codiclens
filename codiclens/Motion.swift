import AppKit
import SwiftUI

/// The whole motion vocabulary, in one place.
///
/// There are two categories and nothing else animates — see
/// `docs/adr/0003-motion-budget.md`. No view outside this file names a spring, a
/// duration, or an easing.
///
/// **Transitions.** Exactly three, and each one carries a change the user
/// caused. Each starts, finishes and is gone.
///
/// - **`entrance`** — the Panel appearing and dismissing. Also the shake, which
///   is a value shaping over this same curve rather than a fourth one.
/// - **`resize`** — a surface changing size: the Card row widening as a Phase is
///   added, a Card's Arrival out of the Card before it, the Results Slab
///   arriving, growing and leaving.
/// - **`snappy`** — scrolling the selection into view.
///
/// Phase advances, Card content swaps and selection movement are **instant, on
/// purpose**. `hardCut()` is how a subtree opts out of an animation its parent
/// is running, which is what lets a surface's size spring while the content
/// inside it changes in one frame.
///
/// Reduce Motion and the user's animations preference are one switch,
/// `isReduced`, and it collapses all three curves to a cross-fade in
/// `collapsed(_:)` — the single place a curve is collapsed.
///
/// **Decoration.** `ringSpin`, and that is the whole of it. A decoration carries
/// no information — nothing about it is learnable — it delays nothing and is
/// never waited on or given a threshold before it appears, and it is simply
/// **absent** under Reduce Motion rather than collapsed. It stays a separate
/// *category* rather than a fourth curve: the budget was never "three is the
/// number", it was *do not animate information*, and a decorative loop touches
/// none of that. The next animation that "just needs to show that something is
/// happening" is a transition wearing decoration's clothes and goes through the
/// three curves.
///
/// **`isReduced` is the app's one accessibility switch, defined here.** It
/// covers Reduce Motion and the app's own animations preference, and three
/// places read it: `collapsed(_:)` in this file, `LoadingRing` — a decoration
/// checks it before drawing at all — and `Style.swift`, where a Card's Arrival
/// checks it to decide whether its glass morphs or is simply there.
enum Motion {

    // MARK: - The three curves

    /// Panel show and hide. Measured frame-by-frame from the reference app: a
    /// ~100ms show whose scale overshoots before it settles, and a ~120ms hide
    /// that kicks *up* one frame first. The overshoot and the kick are shaped in
    /// `PanelEntrance` rather than left to the spring, because the measured
    /// 0.90 → 1.04 → 1.00 excursion is far larger than any spring that settles
    /// this fast produces on its own.
    static var entrance: Animation {
        collapsed(.spring(duration: 0.12, bounce: 0.24))
    }

    /// A surface changing size. Calmer than `entrance` — a Slab that rings after
    /// it has finished growing reads as sloppy rather than lively.
    static var resize: Animation {
        collapsed(.spring(duration: 0.14, bounce: 0.14))
    }

    /// Scroll-to-selection. Short and unconditionally decelerating: the row has
    /// already been chosen, so the scroll is catching up, not deciding.
    static var snappy: Animation {
        collapsed(.easeOut(duration: 0.10))
    }

    /// `resize`, for AppKit. An `NSWindow` frame change goes through
    /// `NSAnimationContext`, which takes a duration and a `CAMediaTimingFunction`
    /// rather than an `Animation` — so the same curve has to be sayable twice.
    /// Keeping both spellings here is what stops the window call site from
    /// declaring a literal of its own.
    static var resizeDuration: TimeInterval {
        isReduced ? crossFadeDuration : 0.14
    }

    static var resizeTimingFunction: CAMediaTimingFunction {
        // A gentle out-curve, matching `resize`'s low bounce. Windows cannot
        // overshoot their own frame convincingly, so this does not try.
        isReduced
            ? CAMediaTimingFunction(name: .linear)
            : CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1)
    }

    // MARK: - Decoration

    // This does not go through `collapsed(_:)`, and that is not an oversight.
    // `collapsed(_:)` turns an `Animation` into a cross-fade, which is
    // meaningless for a loop — there is nothing to cross-fade *to*. So the
    // collapse cannot be delegated to it: a decoration reads `Motion.isReduced`
    // at the point of use and is absent. Whatever the surface said without it,
    // it still says.

    /// The Loading Ring's revolution.
    static let ringSpin: Animation = .linear(duration: 0.85).repeatForever(autoreverses: false)

    // MARK: - Collapsing

    /// The preference key behind the Settings toggle. Default is on; absence of
    /// the key means on.
    static let animationsEnabledKey = "animationsEnabled"

    /// Whether motion is switched off, by the system's Reduce Motion setting or
    /// by the user's own preference. Read through AppKit rather than the SwiftUI
    /// environment so the Panel controller and the views agree.
    static var isReduced: Bool {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return true }
        return !(UserDefaults.standard.object(forKey: animationsEnabledKey) as? Bool ?? true)
    }

    /// How long a collapsed animation takes. Long enough to read as a fade
    /// rather than a cut, short enough not to be waited on.
    fileprivate static let crossFadeDuration: TimeInterval = 0.09

    /// The one place either switch is honoured. Everything that animates goes
    /// through here, so turning motion off cannot be forgotten in a corner.
    private static func collapsed(_ animation: Animation) -> Animation {
        isReduced ? .linear(duration: crossFadeDuration) : animation
    }
}

// MARK: - Panel entrance

/// The measured show and hide, as one progress value shaped into three
/// properties.
///
/// A single spring drives `progress`; opacity, blur and scale are functions of
/// it, which is how three sub-timings come out of one curve. The alternative —
/// three animations with three durations — would be three curves, and the whole
/// point of the budget is that there are not.
///
/// Progress is the same 0 → 1 in both directions; `exiting` swaps which shaping
/// is applied, because the hide is not the show reversed. The show settles into
/// place from small; the hide kicks *up* first and then lets go.
private struct PanelEntrance: ViewModifier, Animatable {
    var progress: Double
    let exiting: Bool
    let reduced: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .center)
            .blur(radius: blur)
            .opacity(opacity)
    }

    // MARK: Measurements

    /// How much blur the Panel arrives out of and leaves into.
    private static let maxBlur: CGFloat = 9

    private static let showStartScale: CGFloat = 0.90
    private static let showPeakScale: CGFloat = 1.04
    /// Progress at which the show's scale peaks. The spring covers this much
    /// ground in roughly the first third of its duration, which is where the
    /// reference app's 1.04 frame sits (~50ms into a ~100ms show).
    private static let showPeakAt: Double = 0.60
    /// Progress by which the show is fully opaque — about 33ms in.
    private static let showOpaqueAt: Double = 0.16
    /// Progress by which the show's blur has cleared — about 85ms in.
    private static let showSharpAt: Double = 0.50

    private static let exitKickScale: CGFloat = 1.02
    /// How far the hide gets before the anticipation kick tops out. Small, and
    /// it matters: without it the Panel reads as switched off rather than as
    /// leaving.
    private static let exitKickAt: Double = 0.88
    /// Progress above which the hide is still fully opaque.
    private static let exitOpaqueTo: Double = 0.70
    /// Progress below which the hide is fully transparent. Deliberately not 0:
    /// the Panel must be invisible *before* the spring settles, because that is
    /// when the window is ordered out.
    private static let exitClearAt: Double = 0.25
    /// Progress below which the hide's blur is fully back in.
    private static let exitBlurredAt: Double = 0.20

    // MARK: Shaping

    /// Clamped, because a spring overshoots its target and the shaping is only
    /// defined on 0...1.
    private var p: Double { min(max(progress, 0), 1) }

    private var opacity: Double {
        if exiting {
            return ramp(p, from: Self.exitClearAt, to: Self.exitOpaqueTo)
        }
        return ramp(p, from: 0, to: Self.showOpaqueAt)
    }

    private var blur: CGFloat {
        guard !reduced else { return 0 }
        if exiting {
            return Self.maxBlur * (1 - CGFloat(ramp(p, from: Self.exitBlurredAt, to: 1)))
        }
        return Self.maxBlur * (1 - CGFloat(ramp(p, from: 0, to: Self.showSharpAt)))
    }

    private var scale: CGFloat {
        guard !reduced else { return 1 }
        if exiting {
            // 1.00 → 1.02 as it lets go, then back to 1.00 while it fades.
            if p >= Self.exitKickAt {
                return lerp(1, Self.exitKickScale, by: (1 - p) / (1 - Self.exitKickAt))
            }
            return lerp(Self.exitKickScale, 1, by: (Self.exitKickAt - p) / Self.exitKickAt)
        }
        if p <= Self.showPeakAt {
            return lerp(Self.showStartScale, Self.showPeakScale, by: p / Self.showPeakAt)
        }
        return lerp(
            Self.showPeakScale, 1,
            by: (p - Self.showPeakAt) / (1 - Self.showPeakAt)
        )
    }

    /// 0 below `from`, 1 above `to`, linear between.
    private func ramp(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        return min(max((value - from) / (to - from), 0), 1)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, by t: Double) -> CGFloat {
        a + (b - a) * CGFloat(min(max(t, 0), 1))
    }
}

// MARK: - Shake

/// A no-match shake: a damped horizontal oscillation, driven by `entrance`.
///
/// Not a fourth curve. `trigger` increments and the spring carries `progress`
/// one whole step; the offset is a sine of the fraction of that step, so it
/// starts at zero, buzzes, and ends at zero without any timing of its own.
/// Phase is measured against the step's own start rather than `floor`, so the
/// spring's overshoot past the target reads as a settled zero instead of
/// wrapping round into a second shake.
private struct Shake: ViewModifier, Animatable {
    var progress: Double
    let target: Double
    let reduced: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// How far the surface travels at the peak of the first swing.
    private static let amplitude: CGFloat = 7
    /// Whole cycles per shake. Whole, so the offset lands back on zero.
    private static let cycles: Double = 3

    private var phase: Double {
        min(max(progress - (target - 1), 0), 1)
    }

    private var offset: CGFloat {
        guard !reduced else { return 0 }
        let decay = 1 - phase
        return Self.amplitude * CGFloat(sin(phase * 2 * .pi * Self.cycles) * decay)
    }

    func body(content: Content) -> some View {
        content.offset(x: offset)
    }
}

// MARK: - The API views use

extension View {

    /// The Panel arriving and leaving. Drive it by flipping `visible` inside
    /// `withAnimation(Motion.entrance)`.
    func panelEntrance(visible: Bool) -> some View {
        modifier(
            PanelEntrance(
                progress: visible ? 1 : 0,
                exiting: !visible,
                reduced: Motion.isReduced
            )
        )
    }

    /// Shakes once each time `trigger` increases. Drive it by incrementing
    /// `trigger` inside `withAnimation(Motion.entrance)`.
    func shake(trigger: Int) -> some View {
        modifier(
            Shake(
                progress: Double(trigger),
                target: Double(trigger),
                reduced: Motion.isReduced
            )
        )
    }

    /// Opts this subtree out of whatever animation an ancestor is running.
    ///
    /// This is what keeps the motion budget honest. A surface's size springs
    /// with `Motion.resize`; the content inside it must change in one frame, or
    /// the user waits on information they already asked for. Applying this
    /// *inside* the animated frame lets the glass stretch while the content it
    /// holds hard-cuts.
    func hardCut() -> some View {
        transaction { $0.animation = nil }
    }
}
