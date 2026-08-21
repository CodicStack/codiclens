import Foundation
import Testing
@testable import codiclens

/// The bundled dataset, checked against what
/// `Scripts/generate-emoji-index.swift` is supposed to have produced.
///
/// These assert on real numbers rather than "not empty" on purpose: the join
/// between emoji-test.txt and the two CLDR files fails *silently* when it goes
/// wrong — rows come out keyword-less, or a whole shape of sequence vanishes —
/// and a count is the only thing that notices.
struct EmojiIndexTests {

    private func makeIndex() throws -> EmojiIndex {
        try EmojiIndex.bundled()
    }

    // MARK: - Shape

    @Test
    func indexHasEveryFullyQualifiedEmoji() throws {
        let index = try makeIndex()
        // Unicode 17.0, fully-qualified, excluding skin-tone variants and the
        // Component group.
        #expect(index.all.count == 1914)
    }

    @Test
    func groupsAreTheNineUnicodeCategories() throws {
        let index = try makeIndex()
        #expect(index.groups == [
            "Smileys & Emotion",
            "People & Body",
            "Animals & Nature",
            "Food & Drink",
            "Travel & Places",
            "Activities",
            "Objects",
            "Symbols",
            "Flags",
        ])
        #expect(index.byGroup().reduce(0) { $0 + $1.emoji.count } == index.all.count)
    }

    @Test
    func versionsAreRecorded() throws {
        let index = try makeIndex()
        #expect(index.unicodeVersion == "17.0")
        #expect(index.cldrVersion == "48")
    }

    // MARK: - Keywords

    @Test
    func everyEmojiHasKeywords() throws {
        let index = try makeIndex()
        let bare = index.all.filter(\.keywords.isEmpty)
        #expect(bare.isEmpty, "no keywords for: \(bare.prefix(10).map(\.string).joined())")
    }

    @Test
    func everyEmojiHasACLDRName() throws {
        let index = try makeIndex()
        // The Unicode names are upper-case-ish and terse; CLDR's are the ones
        // we display. A row that fell back to the Unicode name is a failed join.
        #expect(index.emoji("💪")?.name == "flexed biceps")
        #expect(index.emoji("👍")?.name == "thumbs up")
        #expect(index.emoji("👨‍👩‍👧‍👦")?.name == "family: man, woman, girl, boy")
    }

    @Test
    func keywordsCoverInformalTerms() throws {
        let index = try makeIndex()
        let fire = try #require(index.emoji("🔥"))
        // The reason the dataset exists at all: no Apple API knows 🔥 is "lit".
        #expect(fire.keywords.contains("hot"))
        #expect(fire.keywords.contains("lit"))
    }

    // MARK: - VS16

    @Test
    func emojiCarryingVS16KeepItAndStillJoined() throws {
        let index = try makeIndex()
        // CLDR strips U+FE0F from its keys. The index keeps the fully-qualified
        // form — it is what goes on the pasteboard — so the join has to strip
        // VS16 only for the lookup. Get that wrong and roughly a quarter of the
        // rows come out nameless.
        let pointing = try #require(index.emoji("☝️"))
        #expect(pointing.string.unicodeScalars.contains("\u{FE0F}"))
        #expect(pointing.name == "index pointing up")
        #expect(!pointing.keywords.isEmpty)

        let warning = try #require(index.emoji("⚠️"))
        #expect(warning.name == "warning")
        #expect(!warning.keywords.isEmpty)
    }

    @Test
    func vs16RowsAreNotStrippedInTheIndex() throws {
        let index = try makeIndex()
        // The de-qualified form is not a row: only fully-qualified sequences are.
        #expect(index.emoji("☝") == nil)
    }

    @Test
    func keycapRowsSurviveTheCommentSplit() throws {
        let index = try makeIndex()
        // "# #️⃣" — the name contains the very character the format uses as its
        // comment marker.
        #expect(index.emoji("#️⃣")?.name == "keycap: #")
        #expect(index.emoji("*️⃣")?.name == "keycap: *")
    }

    // MARK: - Skin tones

    @Test
    func skinToneVariantsAreASideTable() throws {
        let index = try makeIndex()
        let total = index.all.reduce(0) { $0 + index.variants(of: $1).count }
        #expect(total == 2030)
        #expect(index.all.filter { index.hasSkinTones($0) }.count == 330)
    }

    @Test
    func skinToneVariantsAreNeverResults() throws {
        let index = try makeIndex()
        // A toned sequence must not be a row of its own.
        #expect(index.emoji("👍🏿") == nil)
        #expect(index.all.allSatisfy { emoji in
            !emoji.string.unicodeScalars.contains { SkinTone.isModifier($0) }
        })
    }

    @Test
    func simpleEmojiResolveToTheirTonedForm() throws {
        let index = try makeIndex()
        let thumbsUp = try #require(index.emoji("👍"))
        #expect(index.emoji(thumbsUp, in: .light).string == "👍🏻")
        #expect(index.emoji(thumbsUp, in: .dark).string == "👍🏿")
        #expect(index.emoji(thumbsUp, in: .none).string == "👍")
    }

    @Test
    func tonedFormsKeepTheirNameAndKeywords() throws {
        let index = try makeIndex()
        let thumbsUp = try #require(index.emoji("👍"))
        let dark = index.emoji(thumbsUp, in: .dark)
        #expect(dark.name == thumbsUp.name)
        #expect(dark.keywords == thumbsUp.keywords)
    }

    @Test
    func vs16IsReplacedByTheModifierInTonedSequences() throws {
        let index = try makeIndex()
        // ⛹️ is U+26F9 U+FE0F; toned it is U+26F9 U+1F3FB — the modifier takes
        // the VS16's place rather than following it. Nothing here may be built
        // by appending.
        let bouncing = try #require(index.emoji("⛹️"))
        let light = index.emoji(bouncing, in: .light)
        #expect(light.string == "⛹🏻")
        #expect(!light.string.unicodeScalars.contains("\u{FE0F}"))
    }

    @Test
    func zwjSequencesTakeTheModifierMidString() throws {
        let index = try makeIndex()
        // 🧑‍🎄 is U+1F9D1 ZWJ U+1F384. The modifier lands after the *base*
        // scalar, before the ZWJ — appending it to the end would produce
        // something that does not render.
        let santa = try #require(index.emoji("🧑‍🎄"))
        let dark = index.emoji(santa, in: .dark)
        #expect(dark.string == "🧑🏿‍🎄")
    }

    @Test
    func sequencesTakingTwoTonesResolveToTheUniformPair() throws {
        let index = try makeIndex()
        // 💏 has 25 variants: five where both people share a tone, encoded as
        // U+1F48F plus one modifier, and twenty mixed pairs spelled out in full
        // as U+1F9D1 <tone> ZWJ … ZWJ U+1F9D1 <tone>. Only a lookup can tell
        // those two encodings apart; the six-tone picker wants the uniform one.
        let kiss = try #require(index.emoji("💏"))
        #expect(index.variants(of: kiss).count == 25)
        #expect(index.variants(of: kiss).contains("🧑🏻‍❤️‍💋‍🧑🏽"))
        #expect(index.emoji(kiss, in: .light).string == "💏🏻")
        #expect(index.emoji(kiss, in: .dark).string == "💏🏿")
    }

    @Test
    func reEncodedTwoToneSequencesAreFiledUnderTheirBase() throws {
        let index = try makeIndex()
        // 🤝 is U+1F91D, but its two-tone forms re-encode entirely as
        // U+1FAF1 <tone> ZWJ U+1FAF2 <tone>. Stripping the tones off those
        // lands on a sequence that is not a row, so they have to be filed by
        // name instead of by shape.
        let handshake = try #require(index.emoji("🤝"))
        #expect(index.variants(of: handshake).count == 25)
        // The uniform light pair is the single-scalar form, not a mixed one.
        #expect(index.emoji(handshake, in: .light).string == "🤝🏻")
    }

    @Test
    func tonesFallBackToTheBaseWhereTheyDoNotApply() throws {
        let index = try makeIndex()
        let grinning = try #require(index.emoji("😀"))
        #expect(!index.hasSkinTones(grinning))
        #expect(index.emoji(grinning, in: .dark).string == "😀")
    }

    // MARK: - Licence

    @Test
    func theUnicodeCopyrightNoticeShips() throws {
        let text = try #require(EmojiIndex.licenseText())
        #expect(text.contains("Unicode"))
        #expect(text.contains("Unicode-3.0"))
    }

    // MARK: - Failure modes

    @Test
    func aMissingResourceIsAnErrorRatherThanACrash() {
        #expect(throws: EmojiIndex.LoadError.self) {
            try EmojiIndex.bundled(in: Bundle(for: InMemoryEmojiRecentsStoreMarker.self))
        }
    }
}

/// A class in the test bundle, so the failure test has a bundle that certainly
/// does not contain the resource.
private final class InMemoryEmojiRecentsStoreMarker {}
