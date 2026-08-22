import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A comet travelling once around a Card's rim: a crisp 1pt head with a tail
/// that blurs out and dissolves behind it.
///
/// It was a 3.5pt bright bar with a stepped opacity falloff before, and the
/// change is paint rather than idea — same `trim`, same over-travel, same
/// `Animatable` drive, same one lap, same meaning of nothing. What moved: the
/// core is 1pt, each of `Style.beamSegments` slices carries its own blur radius
/// (which is the only way a blur can vary along a path), the opacity across the
/// slices is flat because the blur is already the falloff, and the whole layer is
/// masked to the region *outside* the rim so no part of it washes over the Card's
/// content.
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
    private var slices: [Slice] {
        let range = Self.trimRange(phase: phase, tail: Style.beamTailFraction)
        guard range.to > range.from else { return [] }

        let span = range.to - range.from
        let count = max(Style.beamSegments, 1)
        var out: [Slice] = []

        for i in 0..<count {
            let step = span / CGFloat(count)
            let start = seam(range.from + step * CGFloat(i))
            let end = start + step
            let position = Double(i + 1) / Double(count)

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
                    ForEach(slices) { slice in
                        BeamSlice(from: slice.from, to: slice.to, position: slice.position)
                    }
                }
                .mask { Self.outward }
                // The beam is light on the rim, not a hit target. The Card row's
                // own frame is what `hitRegions.cards` reports.
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Outward only

    /// Everything outside the Card's rim, and nothing inside it.
    ///
    /// **The comet's tail is a blur, and a blur spreads both ways.** Unmasked, the
    /// far tail would wash inward across the Card's icon, name and chips — which
    /// is the one thing the effect must not do. So the whole beam layer is masked
    /// to the region outside `Style.cardShape`, applied *after* the blur so it cuts
    /// the halo rather than the source.
    ///
    /// The hard inner edge that leaves, sitting exactly on the rim, is not a
    /// compromise: it *is* the "densest at the border" reading the comet is for.
    /// What it costs is half the stroke — a `.stroke` is centred on its path — and
    /// `Style.beamStrokeWidth` is the measured answer to that.
    ///
    /// The `Rectangle` is grown by a negative padding rather than left at the
    /// layer's bounds, because the overlay is exactly the Card's size and the
    /// outward blur draws past it into `Style.cardInset`'s gutter. A mask that
    /// stopped at the bounds would clip the halo to a hard square edge — the same
    /// class of artefact as "no `.shadow()` on a view that fills its window", one
    /// layer in.
    private static var outward: some View {
        ZStack {
            Rectangle()
                .padding(-Style.beamTailBlur * 2)
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
