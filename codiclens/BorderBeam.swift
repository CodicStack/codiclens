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
/// head is a gradient fill — `BeamBloom`, placed by `bloom` below on the rim point
/// the head currently occupies. A gradient has no edges in any direction, which is
/// both what "a single area/point that a radial blue goes out from" asks for and
/// what makes the head's terminus stop existing rather than merely soften. It was a
/// *circle* for two passes, and a circle centred on a line is a **dot** on that
/// line: it is an ellipse now, long axis along the rim, turned onto the rim's own
/// tangent — "spread it more out kinda like the image".
///
/// **The light is a light blue, in both appearances, and that is not a paint
/// preference — it is what makes the halo's position viable.** It was a saturated
/// blue for two passes (the reference's blue is in its Card's *fill*, and it was
/// read as belonging to the light), then a near-white for two more. Near-white is
/// the one that cost a whole pass: masked outward it composited against the user's
/// wallpaper, and near-white light on a bright hazy sky measured **Δ10/442**. Only a
/// chromatic colour has distance from a white sky *and* a near-black desktop.
///
/// **The halo is outside the rim and the core straddles it, and that split is the
/// sixth correction.** All three parts were masked *outward* for four passes — so
/// the whole effect composited against a desktop the app does not own — then all
/// three *inward*, which fixed the ground and put the halo over the Card's own
/// content, which was rejected on sight. Now: glow and bloom masked outward, core
/// unmasked and centred on the rim, so 1pt of the line always lands on Liquid Glass
/// whatever the wallpaper is. `outward` carries the full finding and
/// `Style.beamWidth` carries the straddle.
///
/// **The halo is smoke, and that is the seventh correction (2026-09-02).** The
/// glow was a band that breathed — one sinusoid on its width — and against the
/// reference it read as too thick and too even: "think about it as a smoke
/// simulation … the beam that runs on the edge should not be too thick". Smoke is
/// light that has aged since it left the head: it expands, diffuses and dissipates
/// along the tail, and it is turbulent, so the plume billows and the wisps drift
/// as the sweep goes round. All of that is `Style.beamSmoke…`, evaluated per slice
/// from `(position, travel)` and nothing else; nothing in this file changed for it
/// except the words. The one shape change that did land here is the **nose**: the
/// glow has no density at the head point and builds up behind it
/// (`Style.beamNose(at:)`), so the front is a taper and the brightest point trails
/// the head. `bloom` still sits on the head point; it is what is ahead of the peak.
///
/// **And then it is the reference, literally — the ninth correction, the same day.**
/// The smoke (a plume that expanded, drifted and dissipated behind the head) read
/// as "a tail thing … looks ass": a coloured wisp floating off the corner, detached
/// from the line. So there is no bloom, no nucleus, no hue and no turbulence any
/// more: a white hairline on the rim that fades along the edge, a 3pt soft glow
/// hugging it outside with the *same* fade, and the nose at the front. Two layers,
/// one fade, all of it outside the Card. `BeamBloom` and `head(in:at:)` are gone.
///
/// **The smoke was outside the rim, all of it — the eighth correction, the same
/// day.** "The beam should never go inside of the card, it should at max hit the
/// edge." The glow and the bloom are under `outward`, cut hard at the rim; the core
/// lights the Card's own hairline and no more (`Style.beamWidth` ≤ 2 × `hairline`).
/// The inward band is deleted. The drop-shadow finding that put the halo inside on
/// 2026-09-01 was about a *wide soft* outward band; this one is 4pt at the head and
/// only wide where it is faint.
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
                    //
                    // **Nothing inside the rim. Ever.** Since 2026-09-02 (second
                    // ask of the day): "the beam should never go inside of the
                    // card, it should at max hit the edge". So the glow and the
                    // bloom are cut to the region *outside* `Style.cardShape` by
                    // `outward`, hard at the rim — smoke leaves the edge and goes
                    // away from the Card — and the core is the one thing that
                    // touches the edge: `Style.beamWidth` is narrow enough that
                    // its inner half lies inside the Card's own hairline rim, so
                    // it lights the border and reaches nothing behind it.
                    // `nothingIsLitInsideTheRim` is that as a number.
                    if Style.beamDrawsGlow {
                        layer(.glow)
                            .mask { Self.outward }
                    }
                    // The core may light the Card's own hairline and nothing behind
                    // it: cut at `hairline` inside the rim, so its blur cannot creep
                    // onto the glass however soft the tail gets.
                    layer(.core)
                        .mask { Self.outward(inset: Style.hairline) }
                }
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

    // MARK: - Outward

    /// Everything outside the Card's rim, and nothing inside it — the mask over the
    /// glow and the bloom. The core is unmasked because it does not need one: see
    /// `Style.beamWidth`, which is bounded so the core never leaves the hairline.
    ///
    /// **Since 2026-09-02 this is the only mask, by instruction: "the beam should
    /// never go inside of the card, it should at max hit the edge."** The inward
    /// band that held the smoke on the glass for one day is deleted. What made the
    /// earlier outward halos read as a drop shadow was a *wide, soft* band whose
    /// brightest point sat off the edge; the smoke is 4pt at its brightest, hard
    /// against the rim, and only wide where it is faint.
    ///
    /// **This has been inverted twice and the history is the reason to read it
    /// before touching it.** For four passes the *whole* comet was masked outward,
    /// on a rule that reads as obviously right: a blur spreads both ways, so cut the
    /// inward half and nothing washes over the Card's icon, name and chips. What that
    /// rule also did was stake the effect's visibility on a ground the app does not
    /// own. Outside a Card's rim there is `Style.cardInset`'s gutter and then the
    /// Panel's own transparent margin, and the Panel is a borderless non-activating
    /// `NSPanel`: outside the rim **is the user's desktop**. Measured on the Card as
    /// `cardSurface(focused:)` actually draws it, dark appearance's near-white head
    /// over a *white* desktop read **Δ10/442** — invisible — against Δ270 over a
    /// near-black one. A factor of twenty-seven decided by somebody's wallpaper, and
    /// **"dark appearance" does not mean "dark ground"**: the appearance sets the
    /// Card's tint and has nothing to do with what is behind the Panel.
    ///
    /// The fifth pass answered that by masking everything *inward*, which fixed the
    /// number (Δ87 over a white desktop) and put the halo over the Card's own
    /// content. That was rejected on sight — "it shouldn't be inside because that
    /// looks ass" — with the halo wanted outside, bigger, and the rim line kept.
    ///
    /// **So the halo is outward and the core is unmasked, and the Δ10 finding is why
    /// the colour had to change first.** A straddling core keeps 1pt of itself on
    /// Liquid Glass, whose polarity is known, so the *line* cannot vanish into a
    /// wallpaper; and the halo is a light blue rather than a near-white, so it has
    /// real distance from a bright sky as well as from a dark desktop. An outward
    /// halo is only viable because of that colour — see `Palette.beamHead`. Get the
    /// colour wrong again and this mask is the Δ10 bug again.
    ///
    /// **A `Rectangle` with the shape punched out, grown by `Style.beamMaskOutset`.**
    /// The growth is not tidiness: an overlay's mask is laid out at the *content's*
    /// size, and the halo is drawn tens of points beyond it, so a mask stopping at
    /// the bounds clips the glow and the bloom into a hard square edge along all four
    /// sides. That artefact is documented from the second pass. `beamMaskOutset` was
    /// correctly deleted while the mask was `cardShape` itself — a region entirely
    /// inside the bounds has no boundary to overrun — and it comes back with the
    /// inversion.
    ///
    /// The cut this leaves is at the rim, radially, and it is not an artefact for the
    /// same reason it never was: what abuts the boundary is the **core** at near-full
    /// alpha, and the core now straddles it, so the eye sees a line's own edge on the
    /// Card's real hairline rim rather than the sheared-off face of a bloom. The
    /// metric that has to stay bounded is the *tangential* step — a terminus along
    /// the beam, which is what "you can see where the border thing ends" was about —
    /// and `BorderBeamRenderTests` pins that at both termini.
    private static var outward: some View { outward(inset: 0) }

    /// `outward`, with the hole shrunk by `inset`: the region outside the Card's
    /// shape inset by that much. The core uses `hairline`, so the Card's own 1pt
    /// rim is the only part of the Card it may touch.
    private static func outward(inset: CGFloat) -> some View {
        Rectangle()
            // The negative padding goes on the *rectangle*, before the overlay,
            // which is the only order that works: a view's overlay is laid out at
            // that view's own layout size, so punching the hole after the growth
            // punches a `cardShape` the size of the Card, in the right place, out of
            // a rectangle that is `beamMaskOutset` bigger in every direction.
            // Growing the composed view instead would grow the hole with it.
            .padding(-Style.beamMaskOutset)
            .overlay {
                Style.cardShape
                    .inset(by: inset)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
    }
}

// MARK: - The design-time loop

/// The `UserDefaults` switch that makes every Card sweep on a fixed period. See
/// `CardBeam` for what it is for and why it is not a timing hack. Kept outside
/// `CardBeam` because a generic type cannot hold a static stored property.
enum BeamLoop {
    static let key = "beamLoop"
    static let period: Double = 1.6
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
            // A design-time loop and nothing else: with
            // `defaults write <bundle id> beamLoop -bool YES` every Card sweeps
            // on a fixed period so the beam can be judged on screen without
            // re-summoning the Panel between looks. This is the one timed loop
            // in the app and it is *not* an exception to the no-timing-hacks
            // rule, because it is not fixing anything: a loop is timed by
            // definition. It has no UI, ships inert, and reads the key once per
            // Card appearance.
            .task {
                guard UserDefaults.standard.bool(forKey: BeamLoop.key) else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(BeamLoop.period))
                    sweep()
                }
            }
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
