import AppKit
import Testing
@testable import codiclens

/// What the Results Slab is handed, and what it costs to hand it over.
struct ResultDisplayTests {

    // MARK: - Identity

    /// A row's id has to come from the thing the row *is*. When it didn't —
    /// when one initialiser minted a `UUID()` per call — every rebuild handed
    /// `ForEach` a brand new set of rows, so the list re-identified itself and
    /// the selection highlight flickered on every keystroke.
    @Test func aRowsIdentityIsStableAcrossRebuilds() {
        let subject = Subject(text: "hello")

        #expect(ResultDisplayItem(from: subject).id == ResultDisplayItem(from: subject).id)
    }

    @Test func twoDifferentThingsGetTwoDifferentIds() {
        #expect(
            ResultDisplayItem(from: Subject(text: "a")).id
                != ResultDisplayItem(from: Subject(text: "b")).id
        )
    }

    /// An app is the bundle at its path, whatever `Subject` the Index made
    /// for this keystroke.
    @Test func anAppRowIsTheSameRowOnEveryKeystroke() {
        let app = { Subject(displayName: "Notes", path: "/Applications/Notes.app", url: nil, icon: NSImage(), kind: .app(bundleIdentifier: nil, isRunning: false)) }

        #expect(ResultDisplayItem(from: app()).id == ResultDisplayItem(from: app()).id)
    }

    @Test func aClipboardRowKeepsItsEntrysIdentity() {
        let item = ClipboardItem(content: "copied")

        #expect(ResultDisplayItem(from: item, imageURL: nil).id == item.id.uuidString)
    }

    // MARK: - Rendering emoji glyphs

    /// The Subject Card asks for a glyph on every body evaluation, so every cell
    /// move used to build a fresh `NSImage`. Deferred drawing makes one
    /// construction cheap; it does not make repeated construction free.
    @Test func thesameGlyphAtTheSameSizeIsRenderedOnce() {
        let first = EmojiRenderer.image(for: "🔥", box: 32)
        let second = EmojiRenderer.image(for: "🔥", box: 32)

        #expect(first === second)
    }

    /// The cache key has to carry the box size. A Card asks for
    /// `Style.cardIcon`, a row asks for 32, and handing one out for the other is
    /// a visibly wrong image.
    @Test func thesameGlyphAtADifferentSizeIsADifferentImage() {
        let small = EmojiRenderer.image(for: "🐈", box: 32)
        let large = EmojiRenderer.image(for: "🐈", box: Style.cardIcon)

        #expect(small !== large)
        #expect(small.size == NSSize(width: 32, height: 32))
        #expect(large.size == NSSize(width: Style.cardIcon, height: Style.cardIcon))
    }

    @Test func differentGlyphsAreDifferentImages() {
        #expect(EmojiRenderer.image(for: "🍎", box: 32) !== EmojiRenderer.image(for: "🍐", box: 32))
    }

    /// The glyph is drawn at a bitmap strike, never between two of them: Apple
    /// Color Emoji resamples visibly in between.
    @Test(arguments: [CGFloat(32), 40, 64, 96, Style.cardIcon])
    func everyBoxSizeLandsOnAStrike(box: CGFloat) {
        #expect(EmojiRenderer.strikes.contains(EmojiRenderer.strike(nearest: box * 0.8)))
    }

    /// The Card's icon slot has to have a strike big enough to fill it. While
    /// the table stopped at 48 and the slot grew to 76, a glyph came out about
    /// 62pt tall next to an app icon that filled all 76.
    @Test func theCardsIconSlotIsDrawnAtTheLargestStrike() {
        #expect(EmojiRenderer.strike(nearest: Style.cardIcon * 0.8) == 64)
    }
}
