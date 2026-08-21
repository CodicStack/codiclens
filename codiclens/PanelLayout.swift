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

    // MARK: - Inside the Results Slab

    /// The Query field's height, and it never changes.
    ///
    /// The field is a bar along the bottom edge of the Slab, not a row in the
    /// flow above it. The Results area takes every point the Slab has spare;
    /// the bar is the same height whether the Query is empty, matches nothing
    /// or matches everything, so it never moves relative to the Slab's bottom
    /// edge. The number is a 13pt line with `Style.rowPaddingV` above and below
    /// it, which is what the field measured before it was pinned.
    ///
    /// It lives here rather than in `Style.swift` because it is geometry —
    /// where a surface's edges are — and `Style` owns radii, materials, tints
    /// and rims.
    static let queryFieldHeight: CGFloat = 30

    /// A one-line message standing in for the Results: "No results", or
    /// "Searching…".
    ///
    /// Neither of them repeats the Query. The field below spells it out, and
    /// interpolating it into the message put the same string on screen twice —
    /// the second time wrapped over three lines, which is most of what made an
    /// empty Slab look like it was holding something.
    static let messageRowHeight: CGFloat = 40

    /// A Result's icon in list Mode.
    static let resultIconSize: CGFloat = 32

    /// One Result row: the icon with `Style.rowPaddingV` above and below it.
    /// The icon is the tallest thing in a row, so it is what sets the height.
    static var resultRowHeight: CGFloat { resultIconSize + Style.rowPaddingV * 2 }

    /// The header over a list of Results — a count, and a chip or two.
    ///
    /// Rounded up rather than measured, and that is safe in one direction only:
    /// it is subtracted from the Results area's ceiling, so being a point or
    /// two generous leaves the Slab a point or two short of `maxResultsHeight`,
    /// while being a point or two mean would let the Slab outgrow it.
    static let resultsHeaderHeight: CGFloat = 34

    /// The shortest the Slab ever gets: one message row and the Query field.
    /// Nothing matched, so there is nothing else in it to be tall.
    static var minResultsHeight: CGFloat { messageRowHeight + queryFieldHeight }

    /// The tallest the scrolling Results area gets, before whatever fixed
    /// furniture sits above it is taken off. The Query field is always under
    /// it, so the ceiling is what is left of `maxResultsHeight` once the bar
    /// has had its share.
    static var maxResultsAreaHeight: CGFloat { maxResultsHeight - queryFieldHeight }

    /// The scrolling Results area's height for content that wants
    /// `contentHeight`, with `chromeHeight` of fixed furniture above it — a
    /// header and its divider, or an open Skin Tone picker.
    ///
    /// This is the Slab's whole variable extent. Everything else in the Slab is
    /// fixed for a given state, so this is what makes the Slab two grid rows
    /// tall when ten Emoji match and full when a thousand do.
    ///
    /// The area is given the result as a **definite** height rather than as a
    /// maximum. A maximum is what the Slab used to carry, and a flexible
    /// maximum inside a window sized to the worst case simply takes the worst
    /// case — a mostly-empty pane with a bar along the bottom of it. A definite
    /// height also keeps the proposal definite all the way down to the
    /// `LazyVStack`: hugging by proposing an *unspecified* height to a lazy
    /// container is how you make it build all 1,914 cells to answer.
    static func resultsAreaHeight(contentHeight: CGFloat, chromeHeight: CGFloat = 0) -> CGFloat {
        min(max(contentHeight, 0), max(maxResultsAreaHeight - chromeHeight, 0))
    }

    /// The height a list of `rows` Results wants, inset above the first row and
    /// below the last.
    static func listContentHeight(rows: Int) -> CGFloat {
        rows > 0 ? CGFloat(rows) * resultRowHeight + Style.resultInset * 2 : 0
    }

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
