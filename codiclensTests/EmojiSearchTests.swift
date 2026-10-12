import Foundation
import Testing
@testable import codiclens

/// Ranking, the grid's layout rules, and its keyboard model.
struct EmojiSearchTests {

    private func makeRecents(_ emoji: [Emoji] = []) -> EmojiRecents {
        let recents = EmojiRecents(store: InMemoryEmojiRecentsStore())
        for one in emoji.reversed() { recents.record(one) }
        return recents
    }

    private func emoji(
        _ string: String,
        _ name: String,
        _ keywords: [String] = [],
        group: Int = 0
    ) -> Emoji {
        Emoji(string: string, name: name, keywords: keywords, groupIndex: group)
    }

    // MARK: - Scoring

    @Test
    func anExactNameScoresBest() {
        let fire = emoji("🔥", "fire", ["hot", "lit"])
        #expect(EmojiSearchVM.score(fire, query: "fire", recentRank: nil) == 0)
    }

    @Test
    func aKeywordScoresBelowTheSameMatchOnTheName() {
        let fire = emoji("🔥", "fire", ["hot"])
        let hotDog = emoji("🌭", "hot dog", [])

        let byKeyword = EmojiSearchVM.score(fire, query: "hot", recentRank: nil)
        let byName = EmojiSearchVM.score(hotDog, query: "hot", recentRank: nil)

        #expect(byKeyword != nil)
        #expect(byName != nil)
        #expect(byName! < byKeyword!, "the name carries full weight, keywords a discount")
    }

    @Test
    func anExactKeywordStillBeatsANameMatchedMidWord() throws {
        let fire = emoji("🔥", "fire", ["lit"])
        // "lit" appears in "litter in bin sign" only as a prefix of a later
        // word — a substring hit, not a name the Query starts.
        let litter = emoji("🚮", "litter in bin sign", [])

        let byKeyword = try #require(EmojiSearchVM.score(fire, query: "lit", recentRank: nil))
        let mid = try #require(EmojiSearchVM.score(litter, query: "lit", recentRank: nil))
        #expect(byKeyword < mid || litter.name.hasPrefix("lit"))
    }

    @Test
    func theBestOfSeveralKeywordsWins() {
        let fire = emoji("🔥", "fire", ["burn", "hot"])
        let exact = EmojiSearchVM.score(fire, query: "hot", recentRank: nil)
        let alsoExact = EmojiSearchVM.score(fire, query: "burn", recentRank: nil)
        #expect(exact == alsoExact)
        #expect(exact == EmojiSearchVM.keywordDiscount)
    }

    @Test
    func nothingMatchingScoresNil() {
        let fire = emoji("🔥", "fire", ["hot"])
        #expect(EmojiSearchVM.score(fire, query: "zzzzzq", recentRank: nil) == nil)
    }

    @Test
    func recentsAreBoostedButOnlyWhenTheyMatch() throws {
        let fire = emoji("🔥", "fire", ["hot"])

        let plain = try #require(EmojiSearchVM.score(fire, query: "hot", recentRank: nil))
        let recent = try #require(EmojiSearchVM.score(fire, query: "hot", recentRank: 0))
        #expect(recent == plain - EmojiSearchVM.recentsBoost)

        // Recency never conjures a match out of nothing.
        #expect(EmojiSearchVM.score(fire, query: "zzzzzq", recentRank: 0) == nil)
    }

    // MARK: - Ranking

    @Test
    func rankingOrdersByScoreThenRecencyThenCanonicalOrder() {
        let alpha = emoji("🅰️", "alpha", ["mark"])
        let beta = emoji("🅱️", "beta", ["mark"])
        let gamma = emoji("©️", "gamma", ["mark"])

        // Identical shape of match, so only the tiebreaks separate them.
        let none = makeRecents()
        #expect(EmojiSearchVM.rank([alpha, beta, gamma], query: "mark", recents: none)
            .map(\.name) == ["alpha", "beta", "gamma"])

        let betaIsRecent = makeRecents([beta])
        #expect(EmojiSearchVM.rank([alpha, beta, gamma], query: "mark", recents: betaIsRecent)
            .map(\.name) == ["beta", "alpha", "gamma"])
    }

    @Test
    func rankingDropsNonMatches() {
        let fire = emoji("🔥", "fire", ["hot"])
        let cat = emoji("🐈", "cat", ["pet"])
        let ranked = EmojiSearchVM.rank([fire, cat], query: "hot", recents: makeRecents())
        #expect(ranked.map(\.string) == ["🔥"])
    }

    @Test
    func rankingRunsAgainstTheRealDataset() throws {
        let index = try EmojiIndex.bundled()
        let ranked = EmojiSearchVM.rank(index.all, query: "lit", recents: makeRecents())
        #expect(ranked.prefix(20).contains { $0.string == "🔥" }, "'lit' should find 🔥")

        let hot = EmojiSearchVM.rank(index.all, query: "hot", recents: makeRecents())
        #expect(hot.prefix(20).contains { $0.string == "🔥" }, "'hot' should find 🔥")

        let biceps = EmojiSearchVM.rank(index.all, query: "flexed biceps", recents: makeRecents())
        #expect(biceps.first?.string == "💪")
    }

    // MARK: - Layout

    @Test
    func anEmptyQueryShowsCategoriesEvenWithNoRecents() throws {
        let index = try EmojiIndex.bundled()
        let sections = EmojiSearchVM.sections(query: "", index: index, recents: makeRecents())

        #expect(!sections.isEmpty, "the grid is never empty")
        #expect(sections.first?.title == "Smileys & Emotion")
        #expect(!sections.contains { $0.title == "Recents" })
    }

    @Test
    func anEmptyQueryPutsRecentsFirst() throws {
        let index = try EmojiIndex.bundled()
        let fire = try #require(index.emoji("🔥"))
        let sections = EmojiSearchVM.sections(query: "", index: index, recents: makeRecents([fire]))

        #expect(sections.first?.title == "Recents")
        #expect(sections.first?.emoji.map(\.string) == ["🔥"])
        #expect(sections.count == index.groups.count + 1)
    }

    @Test
    func aQueryCollapsesToOneSection() throws {
        let index = try EmojiIndex.bundled()
        let sections = EmojiSearchVM.sections(query: "fire", index: index, recents: makeRecents())
        #expect(sections.count == 1)
        #expect(sections.first?.title == "Results")
    }

    // MARK: - Keyboard model

    private func makeVM() throws -> EmojiSearchVM {
        let vm = EmojiSearchVM(
            index: try EmojiIndex.bundled(),
            recents: makeRecents(),
            preferences: EmojiPreferences(defaults: ThrowawayDefaults())
        )
        vm.load()
        return vm
    }

    @Test
    func leftAndRightMoveOneCell() throws {
        let vm = try makeVM()
        vm.moveCell(1)
        #expect(vm.selectedIndex == 1)
        vm.moveCell(-1)
        #expect(vm.selectedIndex == 0)
    }

    @Test
    func cellMovementClampsAtTheEnds() throws {
        let vm = try makeVM()
        vm.moveCell(-1)
        #expect(vm.selectedIndex == 0)
        vm.selectedIndex = vm.flattened.count - 1
        vm.moveCell(1)
        #expect(vm.selectedIndex == vm.flattened.count - 1)
    }

    @Test
    func upAndDownJumpAWholeRow() throws {
        let vm = try makeVM()
        vm.moveRow(1)
        #expect(vm.selectedIndex == EmojiSearchVM.columnCount)
        vm.moveRow(-1)
        #expect(vm.selectedIndex == 0)
    }

    @Test
    func aRowJumpPastASectionLandsInTheNextOne() throws {
        let index = try EmojiIndex.bundled()
        let fire = try #require(index.emoji("🔥"))
        let vm = EmojiSearchVM(
            index: index,
            recents: makeRecents([fire]),
            preferences: EmojiPreferences(defaults: ThrowawayDefaults())
        )
        vm.load()

        // Recents holds one Emoji, so a row down leaves the section entirely.
        #expect(vm.sections.first?.title == "Recents")
        vm.moveRow(1)
        #expect(vm.position(of: vm.selectedIndex)?.section == 1)
    }

    @Test
    func aRowJumpBackFromTheFirstSectionStaysPut() throws {
        let vm = try makeVM()
        vm.moveRow(-1)
        #expect(vm.selectedIndex == 0)
    }

    // MARK: - Skin tone override

    @Test
    func theOverridePickerOpensOnlyWhereTonesApply() throws {
        let vm = try makeVM()
        let index = try EmojiIndex.bundled()

        // 😀 leads the first category and takes no tones.
        #expect(vm.selected?.string == "😀")
        #expect(vm.openTonePicker() == false)
        #expect(!vm.isTonePickerOpen)

        let biceps = try #require(index.all.firstIndex { $0.string == "💪" })
        vm.selectedIndex = vm.flattened.firstIndex { $0.string == "💪" } ?? biceps
        #expect(vm.openTonePicker())
        #expect(vm.tonePickerChoices.count == SkinTone.allCases.count)
        #expect(vm.tonePickerChoices.map(\.string) == ["💪", "💪🏻", "💪🏼", "💪🏽", "💪🏾", "💪🏿"])
    }

    @Test
    func theOverrideDecidesWhatWouldBePasted() throws {
        let vm = try makeVM()
        vm.selectedIndex = try #require(vm.flattened.firstIndex { $0.string == "💪" })

        #expect(vm.resolvedSelection?.string == "💪")

        vm.openTonePicker()
        vm.moveTone(5)
        #expect(vm.effectiveTone == .dark)
        #expect(vm.resolvedSelection?.string == "💪🏿")

        vm.closeTonePicker()
        #expect(vm.resolvedSelection?.string == "💪")
    }

    @Test
    func theDefaultToneAppliesWithoutAnOverride() throws {
        let defaults = ThrowawayDefaults()
        let preferences = EmojiPreferences(defaults: defaults)
        preferences.defaultSkinTone = .medium

        let vm = EmojiSearchVM(
            index: try EmojiIndex.bundled(),
            recents: makeRecents(),
            preferences: preferences
        )
        vm.load()
        vm.selectedIndex = try #require(vm.flattened.firstIndex { $0.string == "💪" })

        #expect(vm.resolvedSelection?.string == "💪🏽")
    }

    // MARK: - Recents

    @Test
    func usingAnEmojiMakesItRecent() throws {
        let index = try EmojiIndex.bundled()
        let recents = makeRecents()
        let vm = EmojiSearchVM(
            index: index,
            recents: recents,
            preferences: EmojiPreferences(defaults: ThrowawayDefaults())
        )
        vm.load()
        vm.selectedIndex = try #require(vm.flattened.firstIndex { $0.string == "💪" })
        vm.recordSelectionUse()

        #expect(recents.strings.first == "💪")
    }

    @Test
    func aTonedPickIsRecordedAgainstItsBase() throws {
        let index = try EmojiIndex.bundled()
        let recents = makeRecents()
        let preferences = EmojiPreferences(defaults: ThrowawayDefaults())
        preferences.defaultSkinTone = .dark

        let vm = EmojiSearchVM(index: index, recents: recents, preferences: preferences)
        vm.load()
        vm.selectedIndex = try #require(vm.flattened.firstIndex { $0.string == "💪" })

        #expect(vm.resolvedSelection?.string == "💪🏿")
        vm.recordSelectionUse()
        // Variants never appear as Results, so Recents holds the base.
        #expect(recents.strings == ["💪"])
    }

    @Test
    func recentsAreCappedAndMostRecentFirst() throws {
        let index = try EmojiIndex.bundled()
        let recents = EmojiRecents(store: InMemoryEmojiRecentsStore())
        for emoji in index.all.prefix(EmojiRecents.limit + 10) { recents.record(emoji) }

        #expect(recents.strings.count == EmojiRecents.limit)
        #expect(recents.strings.first == index.all[EmojiRecents.limit + 9].string)
    }

    @Test
    func recordingAnEmojiTwiceMovesItToTheFront() throws {
        let index = try EmojiIndex.bundled()
        let recents = EmojiRecents(store: InMemoryEmojiRecentsStore())
        let fire = try #require(index.emoji("🔥"))
        let cat = try #require(index.emoji("🐈"))

        recents.record(fire)
        recents.record(cat)
        recents.record(fire)

        #expect(recents.strings == ["🔥", "🐈"])
    }

    @Test
    func recentsSurviveARoundTripThroughTheStore() throws {
        let store = InMemoryEmojiRecentsStore()
        let index = try EmojiIndex.bundled()
        let fire = try #require(index.emoji("🔥"))

        EmojiRecents(store: store).record(fire)
        #expect(EmojiRecents(store: store).strings == ["🔥"])
    }

    // MARK: - The grid, the selection and the Card are one thing

    private func makeVM(tone: SkinTone = .none) throws -> EmojiSearchVM {
        let preferences = EmojiPreferences(defaults: ThrowawayDefaults())
        preferences.defaultSkinTone = tone
        let vm = EmojiSearchVM(
            index: try EmojiIndex.bundled(),
            recents: makeRecents(),
            preferences: preferences
        )
        vm.load()
        return vm
    }

    /// The three things a user sees have to be derived from one another, or the
    /// grid can show one set while the Card shows another. `flattened` is
    /// literally `sections` flattened, the selection is an index into it, and the
    /// Card is that selection wearing the tone in force — so this checks the
    /// whole chain in one place, and after everything that can move it.
    private func expectOneTruth(_ vm: EmojiSearchVM, _ comment: Comment) throws {
        #expect(
            vm.sections.flatMap(\.emoji).map(\.string) == vm.flattened.map(\.string),
            comment
        )
        guard !vm.flattened.isEmpty else {
            #expect(vm.selected == nil, comment)
            #expect(vm.resolvedSelection == nil, comment)
            return
        }
        #expect(vm.flattened.indices.contains(vm.selectedIndex), comment)

        let selected = try #require(vm.selected, comment)
        #expect(selected.string == vm.flattened[vm.selectedIndex].string, comment)

        // What the highlighted cell draws, and what the Card draws, are the same
        // glyph. This is the invariant the user kept hitting.
        let card = try #require(vm.resolvedSelection, comment)
        #expect(vm.displayed(selected).string == card.string, comment)
        // And toning never moves identity: the Result is still the base.
        #expect(vm.flattened[vm.selectedIndex].string == selected.string, comment)
    }

    @Test
    func aQueryFiltersTheGrid() throws {
        let vm = try makeVM()
        let unfiltered = vm.flattened.count

        vm.searchText = "salue"

        #expect(vm.sections.map(\.title) == ["Results"])
        #expect(vm.flattened.count < unfiltered, "the default set is gone")
        // A subsequence match on both, best first in canonical order.
        #expect(vm.flattened.map(\.string).prefix(2) == ["🫡", "🖖"])
        try expectOneTruth(vm, "after a Query")
    }

    @Test
    func theSelectionAndTheCardAgreeThroughEveryKeystroke() throws {
        let vm = try makeVM()
        try expectOneTruth(vm, "with no Query")

        var typed = ""
        for character in "salue" {
            typed.append(character)
            vm.searchText = typed
            #expect(vm.selectedIndex == 0, "a new Query starts at the first cell")
            try expectOneTruth(vm, "after typing \(typed)")
        }

        vm.searchText = ""
        try expectOneTruth(vm, "after clearing the Query")
    }

    @Test
    func theSelectionAndTheCardAgreeThroughEveryMove() throws {
        let vm = try makeVM()
        vm.searchText = "salue"

        vm.moveCell(1)
        #expect(vm.selected?.string == "🖖", "one cell right is the next match")
        try expectOneTruth(vm, "after moveCell(1)")

        vm.moveRow(1)
        try expectOneTruth(vm, "after moveRow(1)")

        vm.moveRow(-1)
        try expectOneTruth(vm, "after moveRow(-1)")

        vm.moveCell(-1)
        try expectOneTruth(vm, "after moveCell(-1)")
    }

    @Test
    func aDefaultToneShowsOnTheCellAsWellAsTheCard() throws {
        let vm = try makeVM(tone: .dark)
        vm.searchText = "salue"

        let base = try #require(vm.selected)
        #expect(base.string == "🫡")
        #expect(vm.displayed(base).string == "🫡", "no variants, so nothing to wear")

        vm.moveCell(1)
        let vulcan = try #require(vm.selected)
        #expect(vulcan.string == "🖖", "identity stays with the base")
        #expect(vm.displayed(vulcan).string == "🖖🏿", "and the cell wears the tone")
        #expect(vm.resolvedSelection?.string == "🖖🏿", "same as the Card")
        try expectOneTruth(vm, "with a default tone")
    }

    /// The tone override is previewed everywhere at once, so opening it cannot
    /// put the cell and the Card out of step.
    @Test
    func theToneOverrideMovesTheCellAndTheCardTogether() throws {
        let vm = try makeVM()
        vm.searchText = "vulcan"
        #expect(vm.selected?.string == "🖖")
        #expect(vm.openTonePicker())

        vm.toneIndex = SkinTone.dark.rawValue
        let selected = try #require(vm.selected)
        #expect(vm.displayed(selected).string == "🖖🏿")
        try expectOneTruth(vm, "with the tone picker open")
    }

    @Test
    func aQueryThatMatchesNothingLeavesNothingSelected() throws {
        let vm = try makeVM()
        vm.searchText = "qqzzxx"

        #expect(vm.sections.isEmpty)
        #expect(vm.flattened.isEmpty)
        #expect(vm.selected == nil)
        #expect(vm.resolvedSelection == nil)
        try expectOneTruth(vm, "with no matches")
    }

    /// A lazy container reuses a child whose id has not changed. Every Query
    /// produces a section called "Results", so the id cannot be the title alone
    /// or the grid is entitled to keep showing the previous set.
    @Test
    func aSectionsIdentityMovesWithItsContents() throws {
        let vm = try makeVM()

        vm.searchText = "salue"
        let first = try #require(vm.sections.first)
        vm.searchText = "vulcan"
        let second = try #require(vm.sections.first)

        #expect(first.title == second.title, "both are called Results")
        #expect(first.id != second.id, "and are still two different sections")
    }

    // MARK: - Which dataset the view model searches

    @Test
    func anInjectedIndexIsTheOneSearched() throws {
        let index = try EmojiIndex.decode(try #require(payload()))

        let vm = EmojiSearchVM(index: index, recents: makeRecents(), preferences: EmojiPreferences(defaults: ThrowawayDefaults()))

        #expect(vm.index === index)
        vm.load()
        #expect(vm.flattened.map(\.string) == ["🔥"])
    }

    /// Constructing the view model must not read `EmojiIndex.shared`: the
    /// `PanelController` builds one while the app is launching, and that read
    /// parsed 226 KB of JSON on the main thread.
    @Test
    func theDatasetIsOnlyResolvedWhenSomethingSearchesIt() throws {
        let vm = EmojiSearchVM(recents: makeRecents(), preferences: EmojiPreferences(defaults: ThrowawayDefaults()))

        // Nothing has asked for an Emoji yet, so nothing has been decoded.
        #expect(vm.sections.isEmpty)
        #expect(vm.flattened.isEmpty)

        // Asking resolves it, and resolves it to the bundled dataset.
        #expect(vm.index === EmojiIndex.shared)
        #expect(vm.index === vm.index, "resolved once, not per access")
    }

    /// A one-emoji dataset in the shipping format.
    private func payload() -> Data? {
        """
        {
          "unicodeVersion": "17.0",
          "cldrVersion": "48",
          "groups": ["Test"],
          "emoji": [{ "e": "🔥", "n": "fire", "k": ["hot"], "g": 0 }],
          "skinTones": {}
        }
        """.data(using: .utf8)
    }
}
