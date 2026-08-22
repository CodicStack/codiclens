import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A comet travelling once around a Card's rim: a **radial bloom** at the head,
/// a **glow** that peaks under it and dies away behind, and a **crisp core** on
/// top of both.
///
/// It was a 3.5pt bright bar, then a single sliced stroke whose blur ramped from
/// 0 at the head, then two sliced strokes at constant opacity, and the drive has
/// never changed — same `trim`, same over-travel, same `Animatable`, same one lap,
/// same meaning of nothing. What has moved four times is the paint, and each
/// correction fixed a thing the previous one could not have known:
///
/// **One layer cannot be crisp and bloomed at once**, because a slice has exactly
/// one blur radius. Choosing crisp at the head left the brightest part of the
/// effect with literally no halo — zero light more than 1pt out from the rim,
/// measured. So the glow is its own sliced stroke, underneath, blurred along the
/// entire lit segment including under the head.
///
/// **A stroke at constant opacity is a tube, not a comet.** The glow's opacity was
/// flat down the whole 303pt segment, on a rule that said blur alone should carry
/// the falloff. Rasterised 4pt outside the rim it read 92 at the head, 100 sixty
/// points behind it, 91 at 180 and 62 at 280 — it *rose* behind the head and then
/// went flat, so nothing peaked anywhere and there was nothing for the light to be
/// coming from. `Style.beamGlowRamp` is the per-slice opacity ramp that fixes it,
/// and it is the glow's alone.
///
/// **A lit line is not a light source, however carefully it is ramped**, so the
/// head is a `RadialGradient` disc — `BeamBloom`, placed by `bloom` below on the
/// rim point the head currently occupies. A disc has no edges in any direction,
/// which is both what "a single area/point that a radial blue goes out from" asks
/// for and what makes the head's terminus stop existing rather than merely soften.
///
/// **The light is white, and the blue in the reference belongs to its Card's
/// fill.** The core was a saturated blue for two passes because that blue was read
/// as belonging to the light; it is now a desaturated near-white highlight, and the
/// halo is mist rather than a cloud. `Style.swift` and
/// `docs/adr/0003-motion-budget.md` carry the numbers, including what light
/// appearance can and cannot do against a light ground.
///
/// All three are masked together to the region outside the rim, so no part of any
/// of them washes over the Card's content. The bloom needs that most: a disc
/// centred on the rim spreads inward exactly as far as outward.
///
/// **It means nothing.** It belongs to a Card *as a surface*: it fires when that
/// Card becomes about something new and that is the whole of it. It is not tied
/// to OCR, to `isOCRInFlight`, to searching, or to any other in-flight or
/// waiting state — reading it as one is the single most likely way this feature
/// gets broken later, which is why it is written here, in
/// `docs/adr/0003-motion-budget.md` and in `CONTEXT.md` all three. OCR Text
/// landing does sweep the Subject Card, and *not* because OCR ran: it sweeps
/// because the Subject was replaced, exactly as a transform's output does.
/// Nothing in this file reads an in-flight flag. It shares a drawing primitive
/// with the Loading Ring — an animated `trim` along a stroked path — and nothing
/// else.
///
/// It ran on the Results Slab's rim before it ran on the Cards'. Nothing about
/// the drawing changed in the move: the shape it strokes is `Style.cardShape`
/// rather than `Style.slabShape`, and every Card being one size is what let
/// `Style.beamSeamOffset` become exact.
///
/// Driven exactly the way `Shake` is driven, and structurally a copy of it: an
/// `Animatable` carrying a `progress` that a `withAnimation` steps one whole
/// unit, with no clock and no `TimelineView` anywhere. Phase is measured against
/// the step's own start rather than by `floor`, which is what lets a re-trigger
/// part-way through a sweep restart cleanly instead of wrapping round into a
/// second lap. `beamSweep` is an `easeOut` and will not overshoot, but the clamp
/// is the same one for the same reason.
///
/// It is `internal` rather than `private` only so `trimRange` can be pinned by a
/// test; everything else about it is as tight as it can be.
struct BorderBeam: ViewModifier, Animatable {
    var progress: Double
    let target: Double
    let reduced: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    // MARK: - The over-travel geometry

    /// The trim range of the lit segment at a given sweep phase.
    ///
    /// Total travel is `1 + tail`, so the head enters through the seam and the
    /// tail leaves through the same seam — one discontinuity-free entry and exit
    /// rather than a beam that pops into being fully formed. `trim`'s clamping
    /// gives the grow-in and the drain-out for free: at phase 0 both ends are 0
    /// and nothing is lit, from the moment `u` passes `tail` the whole segment
    /// is lit, and at phase 1 `u` is `1 + tail` so both ends are 1 and nothing
    /// is lit again.
    static func trimRange(phase: Double, tail: CGFloat) -> (from: CGFloat, to: CGFloat) {
        let u = CGFloat(phase) * (1 + tail)
        return (
            from: min(max(u - tail, 0), 1),
            to: min(max(u, 0), 1)
        )
    }

    // MARK: - Slicing

    /// One flat-coloured sub-stroke of the tail.
    private struct Slice: Identifiable {
        let id: Int
        let from: CGFloat
        let to: CGFloat
        /// 0 at the trailing end of the lit segment, 1 at the head.
        let position: Double
    }

    /// The lit segment, cut into `Style.beamSegments` pieces of equal path
    /// length and rotated onto the seam.
    ///
    /// Equal in the trim parameter, which *is* path length along
    /// `Style.cardShape` — that uniformity is the entire reason the falloff is
    /// built out of slices at all. `trim` is the one primitive in SwiftUI that is
    /// uniform in arc length, and nothing makes a gradient or a blur follow a
    /// path; but each slice is its own view, so per-slice blur is variable blur
    /// along a path. A slice that crosses the seam comes back as two pieces,
    /// because `trim` does not wrap — and both pieces carry the same `position`,
    /// so they carry the same blur radius and the join is invisible.
    ///
    /// One list, drawn twice — once per layer. The two layers are the same
    /// geometry at different widths and blurs, so there is nothing here that knows
    /// which layer it is for.
    ///
    /// **`position` is measured against the *unclamped* travel, not against the
    /// clipped span, and that is the fix for a hard edge parked at the seam.** It
    /// used to be `(i + 1) / count`, which renormalises the whole head-to-tail
    /// range onto whatever is currently on screen — so at both ends of the sweep
    /// the beam drew a complete miniature comet with a full-brightness, zero-blur
    /// head. The drain-out is where that shows: `trimRange` pins `to` at 1 from
    /// phase 0.741 onward while `from` keeps advancing, so for the last quarter of
    /// the lap — 0.14s — the leading end sat *still* at the seam, at maximum
    /// brightness, with the core's `.butt` cap on it. That is a stationary crisp
    /// terminus at the top-left corner, which is what "you can see where the
    /// border thing ends" was pointing at.
    ///
    /// Measured against the travel instead, the head is a *place on the path* that
    /// keeps going after the path runs out: a slice ending at trim `x` is
    /// `u - x` behind it, so `position = 1 - (u - x) / tail`. The arithmetic is
    /// **identical** while the segment is fully extended (substitute
    /// `u = range.to` and it reduces to `(i + 1) / count` exactly), and it only
    /// differs at the two ends — which is the whole point. The drain-out now dims
    /// and blurs the pinned end from 1 down to 0, so there is nothing bright left
    /// at the seam to have a cap; the grow-in draws the *front* of the comet
    /// rather than a compressed copy of all of it.
    private var slices: [Slice] {
        let tail = max(Style.beamTailFraction, 0.0001)
        let range = Self.trimRange(phase: phase, tail: tail)
        guard range.to > range.from else { return [] }

        let travel = CGFloat(phase) * (1 + tail)
        let span = range.to - range.from
        let count = max(Style.beamSegments, 1)
        var out: [Slice] = []

        for i in 0..<count {
            let step = span / CGFloat(count)
            let leading = range.from + step * CGFloat(i + 1)
            let start = seam(range.from + step * CGFloat(i))
            let end = start + step
            let position = Double(min(max(1 - (travel - leading) / tail, 0), 1))

            if end <= 1 {
                out.append(Slice(id: out.count, from: start, to: end, position: position))
            } else {
                out.append(Slice(id: out.count, from: start, to: 1, position: position))
                out.append(Slice(id: out.count, from: 0, to: end - 1, position: position))
            }
        }
        return out
    }

    /// A fraction along `Style.cardShape`'s own path, moved to where the seam is
    /// and wrapped into `0..<1`.
    private func seam(_ fraction: CGFloat) -> CGFloat {
        let shifted = (fraction + Style.beamSeamOffset).truncatingRemainder(dividingBy: 1)
        return shifted < 0 ? shifted + 1 : shifted
    }

    private var phase: Double {
        min(max(progress - (target - 1), 0), 1)
    }

    func body(content: Content) -> some View {
        content.overlay {
            // Absent under Reduce Motion, not slowed down: a travelling
            // highlight has nothing to cross-fade to, so `Motion.collapsed(_:)`
            // cannot express its collapse.
            if !reduced {
                ZStack {
                    // Glow underneath, then the head's bloom, then the core on
                    // top. The two strokes are the same slices of the same trim
                    // range; only the width, the colour, the blur and — on the
                    // glow alone — the opacity ramp differ. The bloom is not a
                    // stroke at all. `Style.beamDrawsGlow` is Reduce
                    // Transparency's answer, and it covers the bloom as well:
                    // the halo goes whole, the crisp sweep stays.
                    if Style.beamDrawsGlow {
                        layer(.glow)
                        bloom
                    }
                    layer(.core)
                }
                .mask { Self.outward }
                // The beam is light on the rim, not a hit target. The Card row's
                // own frame is what `hitRegions.cards` reports.
                .allowsHitTesting(false)
            }
        }
    }

    private func layer(_ which: BeamLayer) -> some View {
        ZStack {
            ForEach(slices) { slice in
                BeamSlice(
                    from: slice.from, to: slice.to,
                    position: slice.position, layer: which
                )
            }
        }
    }

    // MARK: - The nucleus

    /// The radial bloom, placed on the rim wherever the head currently is.
    ///
    /// **Part of the glow, not a third layer.** It is drawn inside the same
    /// `Style.beamDrawsGlow` gate and under the same `outward` mask, so Reduce
    /// Transparency takes the bloom away with the halo and leaves the crisp core
    /// sweeping — which is what that switch has always meant here.
    ///
    /// The `GeometryReader` is how the bloom learns the Card's size; everything
    /// else in this modifier is shape-relative and needs none. It costs the one
    /// path build and the one `trimmedPath` in `headPoint(in:at:)` per frame, and
    /// nothing per slice.
    private var bloom: some View {
        GeometryReader { proxy in
            let tail = max(Style.beamTailFraction, 0.0001)
            let range = Self.trimRange(phase: phase, tail: tail)
            if range.to > range.from,
               let head = Self.headPoint(
                   in: CGRect(origin: .zero, size: proxy.size),
                   at: seam(range.to)
               ) {
                BeamBloom()
                    .frame(width: Style.beamBloomDiameter, height: Style.beamBloomDiameter)
                    // How much of the comet is on the path: `span / tail` is 0 at
                    // both ends of the sweep and 1 whenever the segment is fully
                    // extended. Without it the bloom would appear at full size and
                    // full alpha in the first frame — the disc has extent even
                    // when the lit segment has none — and it would still be parked
                    // at the seam at full strength while the tail drained out,
                    // which is the same stationary-terminus problem `slices` fixes
                    // for the strokes. One expression covers both ends, because
                    // during the drain-out `span / tail` *is* `1 - (u - 1) / tail`.
                    .opacity(min(Double((range.to - range.from) / tail), 1))
                    .position(head)
            }
        }
    }

    /// Where on the rim the head is, at a fraction of `Style.cardShape`'s own
    /// path.
    ///
    /// **Read the *first* point of a short trimmed sub-path.** `currentPoint` on
    /// `trimmedPath(from: 0, to: f)` returns the sub-path's *end* and is `nil` at
    /// f = 0, which is the trap `Style.beamSeamOffset`'s comment already records
    /// being walked into once. A sub-path always opens with a `.move`, so that
    /// case is the one that fires; the others are there so a future change to the
    /// shape cannot make this silently return `nil`.
    ///
    /// Approximate on purpose. `beamSeamOffset` had to be exact to a
    /// ten-thousandth because it decides *where the beam enters the rim* and an
    /// error there is a visible discontinuity every lap. A bloom is a soft disc
    /// 76pt across; being a point or two along the rim from the core's tip is
    /// invisible, so `epsilon` is a plain small number and there is no refinement
    /// loop. One path build and one trim per frame is affordable; forty would not
    /// be.
    static func headPoint(in rect: CGRect, at fraction: CGFloat) -> CGPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let epsilon: CGFloat = 0.002
        let f = min(max(fraction, 0), 1 - epsilon)
        let sub = Style.cardShape.path(in: rect).trimmedPath(from: f, to: f + epsilon)

        var found: CGPoint?
        sub.forEach { element in
            guard found == nil else { return }
            switch element {
            case .move(let point): found = point
            case .line(let point): found = point
            case .curve(_, let control1, _): found = control1
            case .quadCurve(_, let control): found = control
            case .closeSubpath: break
            }
        }
        return found
    }

    // MARK: - Outward only

    /// Everything outside the Card's rim, and nothing inside it.
    ///
    /// **The comet is mostly blur, and a blur spreads both ways.** Unmasked, the
    /// glow would wash inward across the Card's icon, name and chips — which is
    /// the one thing the effect must not do, and it matters far more now that the
    /// glow is a 20pt stroke blurred by up to 20 rather than a 2pt one blurred by
    /// 8. So both layers are masked together to the region outside
    /// `Style.cardShape`, applied *after* the blur so it cuts the halo rather than
    /// the source.
    ///
    /// The hard inner edge that leaves sits exactly on the rim, and the crisp core
    /// sits on top of it — which is why a much brighter glow did not turn that cut
    /// into an artefact. Rasterised, the pixel row immediately outside the rim is
    /// the core at near-full alpha in both appearances, so what abuts the Card's
    /// own edge is a line, not the sheared-off face of a bloom. The "densest at
    /// the border" reading is still what the cut gives, and it is still not a
    /// compromise. What it costs is half of each stroke — a `.stroke` is centred
    /// on its path — which is what `Style.beamStrokeWidth` and
    /// `beamGlowStrokeWidth` both double for.
    ///
    /// The `Rectangle` is grown by a negative padding rather than left at the
    /// layer's bounds, because the overlay is exactly the Card's size and the
    /// glow draws well past it into `Style.cardInset`'s gutter. A mask that
    /// stopped at the bounds would clip the halo to a hard square edge — the same
    /// class of artefact as "no `.shadow()` on a view that fills its window", one
    /// layer in. `Style.beamMaskOutset` is derived from the widest blur so that
    /// raising the glow cannot quietly start clipping it.
    private static var outward: some View {
        ZStack {
            Rectangle()
                .padding(-Style.beamMaskOutset)
            Style.cardShape
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}

// MARK: - The Card-level policy

/// When a Card sweeps: once, each time it becomes about something new.
///
/// **Deliberately separate from `borderBeam(trigger:)`, which stays the
/// primitive.** The primitive is a *drawing* — one lap per increment of an
/// `Int`, knowing nothing about why the number moved — and it is the thing
/// `BorderBeamTests` and `BorderBeamRenderTests` pin. This is the *policy*, and
/// the reason it is a modifier of its own is that it would otherwise be the same
/// three lines of `@State` and `onChange` in `SubjectCardView`, `ActionCardView`
/// and `TargetCardView`. If the trigger is ever narrowed again, this file
/// changes and `BorderBeam` does not.
///
/// The trigger used to be a false→true edge on the Card's own `isFocused`, and
/// that missed every case where a Card became about a *different thing* without
/// the keyboard moving. Four, all reported from the app: Enter on Clipboard
/// (`.searchingSubject` and `.browsingClipboard` are both Query Phases, so the
/// Subject Card's focus never moved), the Subject Card essentially never
/// sweeping at all (already focused when the row is built, and the row is not
/// rebuilt between summons), OCR Text landing, and a text transform's output —
/// the last two both arriving through `CommandCoordinator.retarget`, which
/// replaces the Subject and does not touch the Phase.
///
/// So the trigger is an **identity**: a value naming what this Card is about,
/// and a sweep whenever it changes. `CardBeamIdentity` computes the three, and
/// it computes them as functions of the coordinator rather than as view
/// internals so that `CardBeamIdentityTests` can drive a real coordinator and
/// assert on the tokens.
///
/// **A selection moving inside a Card is not the Card becoming about something
/// else, and must not sweep.** That is a hard constraint, not a preference: in
/// `.searchingSubject` the Subject Card previews the highlighted Result, so a
/// token that tracked the previewed item would strobe the Panel once per arrow
/// key — which is the harm `docs/adr/0003-motion-budget.md` exists to prevent.
/// `CardBeamIdentity` holds no `selectedIndex` for that reason.
///
/// `onAppear` sweeps unconditionally, because a Card that has just been built is
/// about something new by definition. It is also the *only* thing that can
/// sweep the Action and Target Cards on their first arrival: both are
/// conditional on `cardCount` in `CardContainerView`, so reaching
/// `.pickingAction` or `.pickingTarget` inserts a fresh view whose `@State`
/// starts at zero and whose `onChange` therefore never fires. The Subject Card
/// is the opposite case — built once and never rebuilt — which is what
/// `summonGeneration` is in its token for.
private struct CardBeam<ID: Equatable>: ViewModifier {
    let identity: ID

    @State private var trigger = 0

    func body(content: Content) -> some View {
        content
            .borderBeam(trigger: trigger)
            .onChange(of: identity) { sweep() }
            .onAppear { sweep() }
    }

    private func sweep() {
        withAnimation(Motion.beamSweep) { trigger += 1 }
    }
}

// MARK: - What each Card is about

/// The three identity tokens, one per Card: a value that changes when that Card
/// becomes about something new and holds still when a selection merely moves
/// inside it.
///
/// Functions of the coordinator rather than private view properties **on
/// purpose**. The whole rule is a claim about when a token changes and when it
/// does not, and that claim is only checkable if a test can drive a real
/// `CommandCoordinator` and read the tokens back. `CardBeamIdentityTests` does
/// exactly that.
enum CardBeamIdentity {

    // MARK: - The tokens

    /// The Subject Card: the summon, the Phase, and the chosen Subject.
    ///
    /// Three separate reasons for the Card to be about something new, in one
    /// value — so a move that changes two of them at once (Tab, which advances
    /// the Phase *and* chooses the Subject) is still a single change and a
    /// single sweep.
    struct SubjectCard: Equatable {
        let summon: Int
        let phase: CommandCoordinator.Phase
        let chosen: Chosen?
    }

    /// The Action Card: whether it has the keyboard, and whose Actions it lists.
    ///
    /// The Phase is folded down to `holdsKeyboard` rather than carried whole:
    /// the Card sweeps when the Phase *reaches* `.pickingAction`, including
    /// Shift+Tab back from a Target, and a Phase move it is not the destination
    /// of is not news to it. The known consequence is that the same `Bool` also
    /// changes on the way *out* — Tab onward to a Target sweeps the Action Card
    /// once as it hands the keyboard over. That is the one sweep in this file
    /// nobody asked for, and it is the price of the trigger being a pure
    /// function of the state: an arrival cannot be told from a departure without
    /// remembering the previous value, and remembering it is what `CardBeam`'s
    /// `onChange` already does.
    struct ActionCard: Equatable {
        let holdsKeyboard: Bool
        let chosen: Chosen?
    }

    /// The Target Card: whether it has the keyboard, and the Subject and Action
    /// whose Targets these are.
    ///
    /// Deliberately nothing about the Targets themselves. `mdfind` answers out
    /// of process and rewrites `filteredTargets` when it does; that is the list
    /// being *filled in*, not the Card becoming about something else.
    struct TargetCard: Equatable {
        let holdsKeyboard: Bool
        let chosen: Chosen?
        let action: String?
    }

    /// What a chosen `Subject` *is*, as a value.
    ///
    /// Not `Subject.id`: that is a `UUID` minted per instance, so it answers
    /// "is this the same object" when the question is "is this the same thing" —
    /// and `AGENTS.md` already records `ResultDisplayItem.id` being exactly this
    /// mistake. Two Subjects built from the same clipboard entry are the same
    /// thing; a text Subject rewritten by a transform is not.
    ///
    /// Text is carried as a **hash** rather than as itself. OCR Text is a page
    /// of prose and a token is built afresh on every body evaluation of the
    /// Card, so interpolating the string would copy that page per keystroke. A
    /// collision costs a sweep that does not happen, which is a decoration
    /// declining to fire — not a claim about anything.
    enum Chosen: Equatable {
        case app(id: String)
        case file(path: String, type: String)
        case folder(path: String)
        case text(hash: Int)
        case clipboard(id: UUID, textHash: Int)
        case emoji(glyph: String)
        case builtIn(name: String)
    }

    // MARK: - The three

    static func subject(_ coordinator: CommandCoordinator) -> SubjectCard {
        SubjectCard(
            summon: coordinator.summonGeneration,
            phase: coordinator.phase,
            chosen: previewsASelection(coordinator.phase)
                ? nil
                : chosen(coordinator.selectedSubject)
        )
    }

    static func action(_ coordinator: CommandCoordinator) -> ActionCard {
        ActionCard(
            holdsKeyboard: coordinator.phase == .pickingAction,
            chosen: chosen(coordinator.selectedSubject)
        )
    }

    static func target(_ coordinator: CommandCoordinator) -> TargetCard {
        TargetCard(
            holdsKeyboard: coordinator.phase == .pickingTarget,
            chosen: chosen(coordinator.selectedSubject),
            action: coordinator.selectedAction?.name
        )
    }

    // MARK: - Reading the state

    /// Whether the Subject Card is previewing the highlighted Result rather than
    /// naming a chosen Subject — the same set `SubjectCardView.isQueryPhase`
    /// turns on, and for the same reason.
    ///
    /// `selectedSubject` is not what the Card is showing in these Phases, so it
    /// is not read in them. That is not tidiness: `moveUp` and `moveDown` clear
    /// `selectedSubject` while the Clipboard is being browsed, so a token that
    /// read it there would sweep on the first arrow key after entering
    /// Clipboard — a selection moving, which must never sweep.
    private static func previewsASelection(_ phase: CommandCoordinator.Phase) -> Bool {
        switch phase {
        case .searchingSubject, .browsingClipboard, .browsingEmoji: true
        default: false
        }
    }

    private static func chosen(_ subject: Subject?) -> Chosen? {
        guard let subject else { return nil }
        switch subject.kind {
        // `isRunning` is deliberately absent: an app being launched from
        // somewhere else is not this Card becoming about something else.
        case .app(let bundleIdentifier, _):
            return .app(id: bundleIdentifier ?? subject.path ?? subject.displayName)
        case .file(let contentType):
            return .file(
                path: subject.path ?? subject.displayName,
                type: contentType.identifier
            )
        case .folder:
            return .folder(path: subject.path ?? subject.displayName)
        case .text(let rawText):
            return .text(hash: rawText.hashValue)
        case .clipboard(let item):
            return .clipboard(id: item.id, textHash: item.content.hashValue)
        case .emoji(let emoji):
            return .emoji(glyph: emoji.string)
        case .builtIn(.settings):
            return .builtIn(name: "settings")
        case .builtIn(.clipboard):
            return .builtIn(name: "clipboard")
        case .builtIn(.emoji):
            return .builtIn(name: "emoji")
        }
    }
}

// MARK: - The API views use

extension View {

    /// Sweeps the Border Beam once each time `trigger` increases. Drive it by
    /// incrementing `trigger` inside `withAnimation(Motion.beamSweep)`.
    ///
    /// The primitive. `cardBeam(identity:)` is the policy the Cards use; this is
    /// what it draws with.
    func borderBeam(trigger: Int) -> some View {
        modifier(
            BorderBeam(
                progress: Double(trigger),
                target: Double(trigger),
                reduced: Motion.isReduced
            )
        )
    }

    /// Sweeps the Border Beam whenever this Card becomes about something new.
    ///
    /// Pass one of `CardBeamIdentity`'s three tokens. A selection moving inside
    /// the Card must not change it.
    ///
    /// Goes on *after* `cardSurface(focused:)` — the beam runs along the rim the
    /// surface drew — and *before* `.padding(Style.cardInset)`, which sits
    /// outside the surface and would otherwise put the beam on the wrong bounds.
    func cardBeam<ID: Equatable>(identity: ID) -> some View {
        modifier(CardBeam(identity: identity))
    }
}
