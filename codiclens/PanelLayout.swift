import CoreGraphics

/// The Panel's fixed geometry, and which parts of it accept a click.
///
/// There is exactly one Panel — see `docs/adr/0001-single-panel-two-slabs.md` —
/// sized once to its maximum extent and never resized. Everything the user sees
/// is drawn inside it as SwiftUI: a row of Cards at the top, a real gap, then
/// the Results Slab. Both Slabs change size inside a window that does not.
///
/// **Most of the Panel is empty space, and that is the point.** A `.shadow()` on
/// a view that fills its window is clipped by the window bounds and renders as a
/// hard band down two edges instead of a falloff; a scaling entrance animation
/// clips the same way. Both were disabled for exactly that reason. The margin
/// below is what buys them back, so it has to hold the widest layout's scale
/// overshoot *and* a generous shadow beyond that.
///
/// The empty space is not hit-testable — see `PanelHitRegions`.
enum PanelLayout {

    /// One Card. Every Card is this wide whether it has neighbours or not.
    static let cardWidth: CGFloat = 260
    static let cardHeight: CGFloat = 240

    /// Subject, Action, Target — the most Cards any Phase shows.
    static let maxCardCount = 3

    /// The tallest the Results Slab ever gets: a full list or grid, plus its
    /// header, plus the Query field pinned along the bottom, plus the Skin Tone
    /// picker when that is open.
    static let maxResultsHeight: CGFloat = 360

    /// The Card row's width for a Card count, including the row's own padding.
    static func cardRowWidth(_ count: Int) -> CGFloat {
        CGFloat(max(count, 1)) * cardWidth + 20
    }

    /// The widest and tallest the content inside the margin ever gets.
    static var contentWidth: CGFloat { cardRowWidth(maxCardCount) }
    static var contentHeight: CGFloat { cardHeight + Style.gap + maxResultsHeight }

    /// Empty space on all four sides of the content.
    ///
    /// `PanelEntrance` peaks at 1.04 about the centre, which pushes the widest
    /// layout `contentWidth * 0.02 ≈ 16pt` past its own edge. The remaining
    /// ~32pt is room for a surface's shadow to fall off in. Shrink this and the
    /// shadow comes back as a band along the window edge.
    static let margin: CGFloat = 48

    static var panelWidth: CGFloat { contentWidth + margin * 2 }
    static var panelHeight: CGFloat { contentHeight + margin * 2 }

    /// How far the Card row's bottom edge sits above the Panel's bottom edge.
    ///
    /// Centring places *this* line on the screen's vertical midpoint, which is
    /// where the Card row sat when it had a window of its own. The Card row must
    /// not move when the Results Slab arrives or leaves, so the content is
    /// anchored to the top of the Panel and the Slab grows downwards into the
    /// space already reserved for it.
    static var cardRowBottomInset: CGFloat { panelHeight - margin - cardHeight }

    /// The name the Panel's own coordinate space goes by. Both surfaces report
    /// their frames in it, and `PanelHitRegions` is expressed in it.
    static let coordinateSpace = "codiclens.panel"
}

/// The rectangles inside the Panel that accept a click.
///
/// Reported by the SwiftUI layout in the Panel's own coordinate space: origin
/// top-left, y increasing downwards, the size of the whole Panel. Everything
/// outside them — the margin, and the gap between the two Slabs — has to behave
/// like bare desktop, because click-outside-to-dismiss depends on a click there
/// counting as "outside". The Panel is mostly empty space, so getting this wrong
/// breaks dismissal almost everywhere.
struct PanelHitRegions: Equatable {

    /// The Card row. Always present.
    var cards: CGRect = .zero

    /// The Results Slab, or `.zero` when it isn't showing.
    var results: CGRect = .zero

    /// Whether a point in AppKit **window** coordinates — origin bottom-left —
    /// lands on a surface rather than on the margin or the gap.
    ///
    /// - Parameter panelHeight: the Panel's content height, which is what the
    ///   two coordinate systems have to be flipped through.
    func accepts(windowPoint: CGPoint, panelHeight: CGFloat) -> Bool {
        let flipped = CGPoint(x: windowPoint.x, y: panelHeight - windowPoint.y)
        return [cards, results].contains { !$0.isEmpty && $0.contains(flipped) }
    }
}
