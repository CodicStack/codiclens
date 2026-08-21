import AppKit
import Testing
@testable import codiclens

/// The Emoji Mode as the phase machine sees it: getting in, moving around,
/// getting out, and what Enter puts on the pasteboard.
@MainActor
struct EmojiCommandTests {

    private func makeCoordinator() throws -> (CommandCoordinator, RecordingEffectRunner) {
        useInertAppIndex()
        let runner = RecordingEffectRunner()
        let emojiVM = EmojiSearchVM(
            index: try EmojiIndex.bundled(),
            recents: EmojiRecents(store: InMemoryEmojiRecentsStore()),
            preferences: EmojiPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        let coordinator = CommandCoordinator(
            runner: runner,
            history: ClipboardHistory(store: InMemoryClipboardStore()),
            emojiVM: emojiVM
        )
        return (coordinator, runner)
    }

    private func select(_ string: String, in coordinator: CommandCoordinator) throws {
        coordinator.emojiVM.selectedIndex = try #require(
            coordinator.emojiVM.flattened.firstIndex { $0.string == string },
            "\(string) is not in the grid"
        )
    }

    // MARK: - The Built-in

    @Test
    func typingEmojiOffersTheBuiltIn() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.subjectVM.searchText = "emoji"

        let subject = try #require(coordinator.subjectVM.results.first)
        #expect(subject.displayName == "Emoji")
        guard case .builtIn(.emoji) = subject.kind else {
            Issue.record("expected the Emoji Built-in, got \(subject.kind)")
            return
        }
    }

    @Test
    func theBuiltInStaysOutOfTheWayWhenNothingAsksForIt() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.subjectVM.searchText = "zzzzzq"
        #expect(!coordinator.subjectVM.results.contains { $0.displayName == "Emoji" })
    }

    @Test
    func enterOnTheBuiltInOpensTheGridRatherThanRunningAnything() throws {
        let (coordinator, runner) = try makeCoordinator()
        coordinator.subjectVM.searchText = "emoji"

        let effects = coordinator.submit()

        #expect(effects.isEmpty)
        #expect(runner.recorded.isEmpty)
        #expect(coordinator.phase == .browsingEmoji)
        #expect(coordinator.isEmojiBrowsing)
    }

    @Test
    func tabOnTheBuiltInOpensTheGridToo() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.subjectVM.searchText = "emoji"

        coordinator.advancePhase()

        #expect(coordinator.phase == .browsingEmoji)
    }

    // MARK: - The hotkey's way in

    @Test
    func theHotkeyOpensStraightIntoTheGrid() throws {
        let (coordinator, _) = try makeCoordinator()

        // What Ctrl+Cmd+Space does: ask, then let the panel reset itself.
        coordinator.requestEmojiMode()
        coordinator.reset()

        #expect(coordinator.phase == .browsingEmoji)
        #expect(coordinator.currentQuery.isEmpty)
        #expect(!coordinator.emojiVM.sections.isEmpty, "the grid is never empty")
    }

    @Test
    func theRequestIsHonouredOnlyOnce() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.requestEmojiMode()
        coordinator.reset()
        coordinator.reset()

        #expect(coordinator.phase == .searchingSubject)
    }

    @Test
    func anOrdinaryResetLandsInSubjectSearch() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.reset()
        #expect(coordinator.phase == .searchingSubject)
    }

    // MARK: - Escape

    @Test
    func escapeInTheGridDismissesTheWholePanel() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.enterEmojiMode()

        // False means "not consumed", which is how the panel is told to close.
        #expect(coordinator.handleEscape() == false)
        #expect(coordinator.phase == .browsingEmoji, "no fallback to Subject search")
    }

    @Test
    func escapeClosesTheToneOverrideFirst() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.enterEmojiMode()
        try select("💪", in: coordinator)
        #expect(coordinator.toggleSkinTonePicker())

        #expect(coordinator.handleEscape())
        #expect(!coordinator.emojiVM.isTonePickerOpen)
        #expect(coordinator.phase == .browsingEmoji)
    }

    // MARK: - Navigation

    @Test
    func upAndDownJumpARowAndLeftAndRightOneCell() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.enterEmojiMode()

        coordinator.moveDown()
        #expect(coordinator.emojiVM.selectedIndex == EmojiSearchVM.columnCount)

        #expect(coordinator.moveRight())
        #expect(coordinator.emojiVM.selectedIndex == EmojiSearchVM.columnCount + 1)

        #expect(coordinator.moveLeft())
        #expect(coordinator.emojiVM.selectedIndex == EmojiSearchVM.columnCount)

        coordinator.moveUp()
        #expect(coordinator.emojiVM.selectedIndex == 0)
    }

    @Test
    func leftAndRightAreIgnoredOutsideTheGrid() throws {
        let (coordinator, _) = try makeCoordinator()
        #expect(coordinator.moveLeft() == false)
        #expect(coordinator.moveRight() == false)
    }

    @Test
    func theToneOverrideTakesOverLeftAndRight() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.enterEmojiMode()
        try select("💪", in: coordinator)
        let cell = coordinator.emojiVM.selectedIndex

        coordinator.toggleSkinTonePicker()
        coordinator.moveRight()
        coordinator.moveRight()

        #expect(coordinator.emojiVM.toneIndex == 2)
        #expect(coordinator.emojiVM.selectedIndex == cell, "the grid selection stays put")
    }

    @Test
    func theToneOverrideRefusesEmojiWithoutTones() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.enterEmojiMode()
        try select("😀", in: coordinator)

        #expect(coordinator.toggleSkinTonePicker() == false)
        #expect(!coordinator.emojiVM.isTonePickerOpen)
    }

    // MARK: - Enter

    @Test
    func enterPastesTheEmoji() throws {
        let (coordinator, runner) = try makeCoordinator()
        coordinator.enterEmojiMode()
        try select("🔥", in: coordinator)

        let effects = coordinator.submit()

        // The Clipboard paste path exactly: one `.paste`, which the runner
        // turns into dismiss, focus handoff, then Cmd+V.
        #expect(effects == [.paste(.text("🔥"))])
        #expect(runner.recorded == effects)
    }

    @Test
    func enterPastesTheOverriddenTone() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.enterEmojiMode()
        try select("💪", in: coordinator)
        coordinator.toggleSkinTonePicker()
        coordinator.emojiVM.toneIndex = SkinTone.dark.rawValue

        #expect(coordinator.submit() == [.paste(.text("💪🏿"))])
    }

    @Test
    func enterPastesTheDefaultTone() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.defaultSkinTone = .mediumLight
        coordinator.enterEmojiMode()
        try select("💪", in: coordinator)

        #expect(coordinator.submit() == [.paste(.text("💪🏼"))])
    }

    @Test
    func pastingMakesTheEmojiRecent() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.enterEmojiMode()
        try select("🔥", in: coordinator)
        coordinator.submit()

        #expect(coordinator.emojiVM.recents.strings.first == "🔥")

        // And Recents lead the grid next time round.
        coordinator.enterEmojiMode()
        #expect(coordinator.emojiVM.sections.first?.title == "Recents")
    }

    // MARK: - Actions

    @Test
    func tabOffersPasteThenCopy() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.enterEmojiMode()
        try select("🔥", in: coordinator)

        coordinator.advancePhase()

        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.actionVM.filteredActions.map(\.name) == ["Paste", "Copy"])
    }

    @Test
    func copyWritesTheEmojiAndDismisses() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.enterEmojiMode()
        try select("🔥", in: coordinator)
        coordinator.advancePhase()
        coordinator.actionVM.selectedIndex = 1

        #expect(coordinator.submit() == [.hide, .copy(.text("🔥"))])
    }

    @Test
    func shiftTabFromActionsGoesBackToTheGrid() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.enterEmojiMode()
        try select("🔥", in: coordinator)
        coordinator.advancePhase()

        coordinator.retreatPhase()

        #expect(coordinator.phase == .browsingEmoji)
    }

    @Test
    func theSubjectCarriesTheCLDRName() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.enterEmojiMode()
        try select("💪", in: coordinator)
        coordinator.advancePhase()

        let subject = try #require(coordinator.selectedSubject)
        #expect(subject.displayName == "flexed biceps")
        #expect(subject.subtitle == "💪")
        #expect(subject.emoji?.string == "💪")
    }

    // MARK: - Searching inside the grid

    @Test
    func typingFiltersTheGrid() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.enterEmojiMode()

        coordinator.currentSearchText = "lit"

        #expect(coordinator.emojiVM.sections.map(\.title) == ["Results"])
        #expect(coordinator.emojiVM.flattened.prefix(20).contains { $0.string == "🔥" })
    }

    @Test
    func clearingTheQueryBringsTheCategoriesBack() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.enterEmojiMode()
        coordinator.currentSearchText = "fire"
        coordinator.currentSearchText = ""

        #expect(coordinator.emojiVM.sections.count == coordinator.emojiVM.index.groups.count)
        #expect(!coordinator.emojiVM.flattened.isEmpty)
    }
}
