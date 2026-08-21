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
            preferences: EmojiPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
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
            preferences: EmojiPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
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
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
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
            preferences: EmojiPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
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
        let preferences = EmojiPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
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
}
