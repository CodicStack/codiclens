import CoreGraphics
import Testing
@testable import codiclens

/// The Panel's fixed geometry, and the rule that decides which clicks count as
/// landing on it.
///
/// This matters more than it looks. The Panel is one window sized to its maximum
/// extent, so most of it is empty space — a margin all the way round and a real
/// gap between the two Slabs. Click-outside-to-dismiss depends on a click in
/// that space being treated as *outside*, and the two coordinate systems
/// involved disagree about which way y goes: AppKit measures a window from its
/// bottom-left, SwiftUI reports frames from the top-left.
struct PanelLayoutTests {

    // MARK: - The margin

    @Test func theMarginLeavesRoomForTheEntranceOvershootAndAShadow() {
        // `PanelEntrance` peaks at 1.04 about the centre, so the widest layout
        // pushes 2% of its width past its own edge on each side.
        let overshoot = PanelLayout.contentWidth * 0.02

        #expect(PanelLayout.margin > overshoot)
        #expect(
            PanelLayout.margin - overshoot >= Style.shadowRadius,
            "whatever is left over has to be enough for the shadow to fall off in"
        )
        #expect(PanelLayout.margin - Style.shadowRadius - Style.shadowY > 0)
    }

    @Test func thePanelIsBiggerThanItsContentOnAllFourSides() {
        #expect(PanelLayout.panelWidth == PanelLayout.contentWidth + PanelLayout.margin * 2)
        #expect(PanelLayout.panelHeight == PanelLayout.contentHeight + PanelLayout.margin * 2)
    }

    @Test func theContentIsTheWidestCardRowAndTheTallestSlabWithAGapBetween() {
        #expect(PanelLayout.contentWidth == PanelLayout.cardRowWidth(PanelLayout.maxCardCount))
        #expect(
            PanelLayout.contentHeight
                == PanelLayout.cardHeight + Style.gap + PanelLayout.maxResultsHeight
        )
    }

    /// Centring puts this line on the screen's vertical midpoint, so it has to
    /// describe the Card row's bottom edge and nothing else.
    @Test func theCardRowSitsUnderTheTopMargin() {
        #expect(
            PanelLayout.cardRowBottomInset
                == Style.gap + PanelLayout.maxResultsHeight + PanelLayout.margin
        )
    }

    // MARK: - The Slab is sized to its content

    /// The Query field is a bar along the bottom edge, not a row in the flow:
    /// the Results area above it takes every point going, and the bar is the
    /// same height in every state.
    @Test func theQueryFieldIsAFixedBarAndTheResultsAreaTakesTheRest() {
        #expect(PanelLayout.queryFieldHeight > 0)
        #expect(
            PanelLayout.maxResultsAreaHeight + PanelLayout.queryFieldHeight
                == PanelLayout.maxResultsHeight,
            "the bar's share comes off the ceiling, so the two of them are the ceiling"
        )
    }

    /// The bar does not grow, shrink or move as the Results change. Whatever the
    /// area comes out as, the field contributes the same.
    @Test(arguments: [0, 40, 116, 260, 10_000] as [CGFloat])
    func theQueryFieldsHeightDoesNotDependOnTheResults(content: CGFloat) {
        let area = PanelLayout.resultsAreaHeight(contentHeight: content)
        let slab = area + PanelLayout.queryFieldHeight
        #expect(slab - area == PanelLayout.queryFieldHeight)
    }

    @Test func theResultsAreaIsAsTallAsWhatItHolds() {
        #expect(PanelLayout.resultsAreaHeight(contentHeight: 0) == 0)
        #expect(PanelLayout.resultsAreaHeight(contentHeight: 84) == 84)
        #expect(PanelLayout.resultsAreaHeight(contentHeight: -10) == 0)
    }

    @Test func theResultsAreaStopsAtTheCeilingLessItsFurniture() {
        #expect(
            PanelLayout.resultsAreaHeight(contentHeight: 10_000)
                == PanelLayout.maxResultsAreaHeight
        )

        let chrome = PanelLayout.resultsHeaderHeight + Style.hairline
        #expect(
            PanelLayout.resultsAreaHeight(contentHeight: 10_000, chromeHeight: chrome)
                == PanelLayout.maxResultsAreaHeight - chrome
        )
        #expect(
            PanelLayout.resultsAreaHeight(contentHeight: 10_000, chromeHeight: 10_000) == 0,
            "furniture taller than the Slab leaves no area rather than a negative one"
        )
    }

    /// The Panel reserves `maxResultsHeight` for the Slab and never resizes, so
    /// no state may add up to more than that.
    @Test func noStateLetsTheSlabOutgrowTheSpaceReservedForIt() {
        let furniture: [CGFloat] = [
            0,
            PanelLayout.resultsHeaderHeight + Style.hairline,
            PanelLayout.messageRowHeight,
            PanelLayout.maxResultsAreaHeight,
        ]
        for chrome in furniture {
            for content in [0, 60, 300, 10_000] as [CGFloat] {
                let slab = PanelLayout.resultsAreaHeight(
                    contentHeight: content, chromeHeight: chrome
                ) + chrome + PanelLayout.queryFieldHeight
                #expect(slab <= PanelLayout.maxResultsHeight)
            }
        }
    }

    /// The smallest the Slab can ever be: one message row and the Query bar.
    /// This is the no-match state, and it used to be a full-height pane with a
    /// bar at the bottom of it.
    @Test func aSlabHoldingOnlyNoResultsAndTheQueryBarIsShort() {
        #expect(
            PanelLayout.minResultsHeight
                == PanelLayout.messageRowHeight + PanelLayout.queryFieldHeight
        )
        #expect(PanelLayout.resultsAreaHeight(contentHeight: 0) == 0, "there is no area at all")
        #expect(
            PanelLayout.minResultsHeight < PanelLayout.maxResultsHeight / 4,
            "under a quarter of the space reserved for the Slab"
        )
    }

    @Test func aListGrowsOneRowAtATime() {
        #expect(PanelLayout.listContentHeight(rows: 0) == 0)
        #expect(
            PanelLayout.listContentHeight(rows: 1)
                == PanelLayout.resultRowHeight + Style.resultInset * 2
        )
        #expect(
            PanelLayout.listContentHeight(rows: 4) - PanelLayout.listContentHeight(rows: 3)
                == PanelLayout.resultRowHeight
        )
    }

    /// The reported defect: `salue` matches about ten Emoji, and the Slab used
    /// to stay near its full height to show two short rows.
    @Test func tenMatchingEmojiMakeAShortSlab() {
        let content = EmojiGridView.contentHeight(sectionCellCounts: [10])
        let slab = PanelLayout.resultsAreaHeight(contentHeight: content)
            + PanelLayout.queryFieldHeight

        #expect(content < PanelLayout.maxResultsAreaHeight, "two rows are nowhere near the ceiling")
        #expect(
            slab < PanelLayout.maxResultsHeight / 2,
            "under half the space reserved for the Slab"
        )
    }

    @Test func aGridSectionRoundsUpToWholeRowsOfCells() {
        let one = EmojiGridView.contentHeight(sectionCellCounts: [1])
        let full = EmojiGridView.contentHeight(
            sectionCellCounts: [EmojiSearchVM.columnCount]
        )
        let spilling = EmojiGridView.contentHeight(
            sectionCellCounts: [EmojiSearchVM.columnCount + 1]
        )

        #expect(one == full, "one cell and a full row are both one row")
        #expect(spilling > full)
        #expect(EmojiGridView.contentHeight(sectionCellCounts: []) == 0)
    }

    @Test func aSectionCostsMoreThanItsCells() {
        let together = EmojiGridView.contentHeight(sectionCellCounts: [12])
        let split = EmojiGridView.contentHeight(sectionCellCounts: [6, 6])
        #expect(split > together, "the same cells under two headings are taller")
    }

    /// Browsing with no Query: every category at once, which is far more than
    /// fits, so the Slab is exactly as tall as the Panel reserved for it.
    @Test func theWholeDatasetFillsTheSlabToItsCeiling() {
        let content = EmojiGridView.contentHeight(
            sectionCellCounts: Array(repeating: 200, count: 10)
        )
        let slab = PanelLayout.resultsAreaHeight(contentHeight: content)
            + PanelLayout.queryFieldHeight

        #expect(content > PanelLayout.maxResultsAreaHeight)
        #expect(slab == PanelLayout.maxResultsHeight)
    }

    // MARK: - Which clicks land on the Panel

    /// The layout as SwiftUI would report it: Cards under the top margin,
    /// Results Slab a gap below them, both horizontally centred.
    private var regions: PanelHitRegions {
        let cardWidth = PanelLayout.cardRowWidth(1)
        let x = (PanelLayout.panelWidth - cardWidth) / 2
        return PanelHitRegions(
            cards: CGRect(
                x: x, y: PanelLayout.margin,
                width: cardWidth, height: PanelLayout.cardHeight
            ),
            results: CGRect(
                x: x, y: PanelLayout.margin + PanelLayout.cardHeight + Style.gap,
                width: cardWidth, height: 120
            )
        )
    }

    /// A point in the SwiftUI space, as AppKit would report the same point.
    private func windowPoint(fromTopLeft point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: PanelLayout.panelHeight - point.y)
    }

    private func accepts(topLeft point: CGPoint, _ regions: PanelHitRegions) -> Bool {
        regions.accepts(
            windowPoint: windowPoint(fromTopLeft: point),
            panelHeight: PanelLayout.panelHeight
        )
    }

    @Test func aClickOnACardLandsOnThePanel() {
        #expect(accepts(topLeft: CGPoint(x: regions.cards.midX, y: regions.cards.midY), regions))
    }

    @Test func aClickOnTheResultsSlabLandsOnThePanel() {
        #expect(accepts(topLeft: CGPoint(x: regions.results.midX, y: regions.results.midY), regions))
    }

    @Test func aClickInTheGapBetweenTheSlabsIsOutside() {
        let gapMiddle = CGPoint(
            x: regions.cards.midX,
            y: regions.cards.maxY + Style.gap / 2
        )
        #expect(accepts(topLeft: gapMiddle, regions) == false)
    }

    @Test(arguments: [
        CGPoint(x: 4, y: 4),                                  // top-left margin
        CGPoint(x: PanelLayout.panelWidth - 4, y: 4),          // top-right
        CGPoint(x: 4, y: PanelLayout.panelHeight - 4),         // bottom-left
        CGPoint(x: PanelLayout.panelWidth / 2, y: 4),          // above the Cards
        CGPoint(x: PanelLayout.panelWidth / 2,
                y: PanelLayout.panelHeight - 4),               // below the Slab
    ])
    func aClickOnTheMarginIsOutside(point: CGPoint) {
        #expect(accepts(topLeft: point, regions) == false)
    }

    @Test func aClickBesideTheCardRowIsOutside() {
        let besideCards = CGPoint(x: regions.cards.minX - 8, y: regions.cards.midY)
        #expect(accepts(topLeft: besideCards, regions) == false)
    }

    /// The Slab surrenders its region when it leaves. Without that, clicks keep
    /// landing on a surface that is no longer on screen.
    @Test func aClickWhereAnAbsentSlabUsedToBeIsOutside() {
        var withoutResults = regions
        let wasAt = CGPoint(x: withoutResults.results.midX, y: withoutResults.results.midY)
        withoutResults.results = .zero

        #expect(accepts(topLeft: wasAt, withoutResults) == false)
        #expect(
            accepts(topLeft: CGPoint(x: regions.cards.midX, y: regions.cards.midY), withoutResults),
            "the Card row is unaffected"
        )
    }

    /// The Slab is sized to its content, so most of the space the Panel reserved
    /// for it is empty whenever little matches — and a click in that space has to
    /// dismiss the Panel. The reported region has to shrink with the Slab for it
    /// to: the frame comes from the layout, never from `maxResultsHeight`.
    @Test func aClickBelowAContentSizedSlabIsOutside() {
        let content = EmojiGridView.contentHeight(sectionCellCounts: [10])
        let height = PanelLayout.resultsAreaHeight(contentHeight: content)
            + PanelLayout.queryFieldHeight

        var short = regions
        short.results = CGRect(
            x: regions.results.minX, y: regions.results.minY,
            width: regions.results.width, height: height
        )

        #expect(
            accepts(topLeft: CGPoint(x: short.results.midX, y: short.results.maxY - 2), short),
            "the Query bar along the bottom edge is still the Slab"
        )
        #expect(
            accepts(topLeft: CGPoint(x: short.results.midX, y: short.results.maxY + 8), short)
                == false,
            "and the reserved space below it is not"
        )

        // Where the Slab's bottom edge would have been had it stayed full height.
        let reservedBottom = PanelLayout.margin + PanelLayout.cardHeight + Style.gap
            + PanelLayout.maxResultsHeight - 2
        #expect(short.results.maxY < reservedBottom)
        #expect(accepts(topLeft: CGPoint(x: short.results.midX, y: reservedBottom), short) == false)
    }

    @Test func anEmptyLayoutAcceptsNothing() {
        let empty = PanelHitRegions()
        #expect(accepts(topLeft: CGPoint(x: 100, y: 100), empty) == false)
        #expect(accepts(topLeft: .zero, empty) == false)
    }
}
