import CoreGraphics

/// The Panel's fixed geometry, and which parts of it accept a click.
///
/// There is exactly one Panel — see `docs/adr/0001-single-panel-two-slabs.md` —
/// sized once to its maximum extent and never resized. Everything the user sees
/// is drawn inside it as SwiftUI: a row of Cards at the top, a real gap, then
/// the Results Slab, and the Update Notice a gap under it. Both Slabs change size inside a window that does not.
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

    /// One Card's **cell**. Every Card gets one, whether it has neighbours or not.
    ///
    /// The drawn glass surface is smaller than this by `Style.cardInset` on every
    /// side, because that padding sits *outside* the surface: 212 × 212 less 6
    /// twice is a **200 × 200** Card, and two neighbouring insets are the 12pt
    /// gutter between two of them.
    ///
    /// Square, because a Card is an icon with a name under it and nothing else.
    static let cardWidth: CGFloat = 212
    static let cardHeight: CGFloat = 212

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

    /// The shortest Slab that is *saying* something: one message row and the
    /// Query field. Nothing matched, so there is nothing else in it to be tall.
    static var minResultsHeight: CGFloat { messageRowHeight + queryFieldHeight }

    /// The Slab with nothing in it but the Query bar, and the shortest it gets.
    ///
    /// A real state, not a degenerate one: while the app Index is still being
    /// built, a Subject search has no Results *and* no right to say "No
    /// results", so the message row is absent and the bar stands alone. The
    /// Slab hugs its content, so this is simply what it measures — the number
    /// exists so the arithmetic can be pinned rather than assumed.
    static var queryOnlyResultsHeight: CGFloat { queryFieldHeight }

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

    /// The Card row's width for a Card count: one cell per Card and nothing
    /// else.
    ///
    /// Exact rather than generous, so the arithmetic above is true on screen:
    /// each cell is `cardWidth` wide, each carries `Style.cardInset` of padding
    /// outside its own glass, and two neighbouring insets are the gutter. The
    /// Results Slab is given this width too wherever it is wide enough to be
    /// worth having — see `slabWidth` — which puts its edges one inset outside
    /// the outermost Card's glass.
    static func cardRowWidth(_ count: Int) -> CGFloat {
        CGFloat(max(count, 1)) * cardWidth
    }

    /// The narrowest the Results Slab ever gets, whatever the Card row is
    /// doing above it.
    ///
    /// The Slab is the larger, calmer surface of the two, and it does not have
    /// to be as narrow as a lone Card: the `VStack` centres it under the Card
    /// row, so a wider Slab stays symmetrical about the same axis. This is the
    /// width the Slab had under one Card before the Cards shrank to
    /// `cardWidth`, and the Emoji grid's five fixed cells were laid out for it
    /// — at the old width they fit with their insets, at 212 they are clipped
    /// along the right edge.
    static let slabMinWidth: CGFloat = 304

    /// The Results Slab's width for a Card count: the Card row's width, unless
    /// that is narrower than the Slab is allowed to be.
    ///
    /// Two Cards and up, this is `cardRowWidth` exactly, so the Slab's edges
    /// sit one inset outside the outermost Card's glass. Under one Card the
    /// floor wins and the Slab overhangs the Card on both sides.
    static func slabWidth(_ cardCount: Int) -> CGFloat {
        max(cardRowWidth(cardCount), slabMinWidth)
    }

    // MARK: - The Update Notice

    /// The Update Notice's strip: one 12pt line with the ⌘U chip beside it,
    /// `Style.rowPaddingV` above and below. Definite, so the Panel's reserve
    /// for it is arithmetic.
    static let updateNoticeHeight: CGFloat = 30

    /// The strip is as wide as what it sits under: the preview, or the
    /// Results Slab (`slabWidth`, which is also the width the Slab would have
    /// when the strip sits under the Card row alone, and wide enough for the
    /// longest line under one Card).
    static func updateNoticeWidth(cardCount: Int, underPreview: Bool) -> CGFloat {
        underPreview ? contentWidth : slabWidth(cardCount)
    }

    /// The widest and tallest the content inside the margin ever gets.
    ///
    /// The Slab is written into the max as well as the Card row. Three Cards
    /// is 636 and already dominates `slabMinWidth`, so the second term never
    /// bites today — it is there so the invariant is stated rather than
    /// assumed: nothing inside the margin is wider than this.
    static var contentWidth: CGFloat { max(cardRowWidth(maxCardCount), slabMinWidth) }
    ///
    /// The height reserves room for the Update Notice under the tallest Slab
    /// whether or not one is showing: the Panel is never resized, so the strip
    /// cannot ask for room when it arrives.
    static var contentHeight: CGFloat {
        cardHeight + Style.gap + maxResultsHeight + Style.gap + updateNoticeHeight
    }

    /// Empty space on all four sides of the content.
    ///
    /// `PanelEntrance` peaks at 1.04 about the centre, which pushes the widest
    /// layout `contentWidth * 0.02 ≈ 13pt` past its own edge. What is left is
    /// room for a surface's shadow — the Slab's own, and the one native glass
    /// draws under a Card — to fall off in. Shrink this and the shadow comes back
    /// as a band along the window edge.
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
/// outside them — the margin, and the gaps between the surfaces — has to behave
/// like bare desktop, because click-outside-to-dismiss depends on a click there
/// counting as "outside". The Panel is mostly empty space, so getting this wrong
/// breaks dismissal almost everywhere.
struct PanelHitRegions: Equatable {

    /// The Card row. Always present.
    var cards: CGRect = .zero

    /// The Results Slab, or `.zero` when it isn't showing.
    var results: CGRect = .zero

    /// The Update Notice, or `.zero` when no update is waiting.
    var notice: CGRect = .zero

    /// Whether a point in AppKit **window** coordinates — origin bottom-left —
    /// lands on a surface rather than on the margin or the gap.
    ///
    /// - Parameter panelHeight: the Panel's content height, which is what the
    ///   two coordinate systems have to be flipped through.
    func accepts(windowPoint: CGPoint, panelHeight: CGFloat) -> Bool {
        let flipped = CGPoint(x: windowPoint.x, y: panelHeight - windowPoint.y)
        return [cards, results, notice].contains { !$0.isEmpty && $0.contains(flipped) }
    }
}
