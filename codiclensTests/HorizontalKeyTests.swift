import Testing
@testable import codiclens

/// Left/Right, bare or with Control, are exactly Ctrl+H/L: all of them go
/// through `stepHorizontally`, the grid first, then the Phase. A typed Query
/// changes nothing, so the arrows never vanish into an invisible caret.
@MainActor
struct HorizontalKeyTests {

    private func makeCoordinator(seededWith texts: [String] = []) -> CommandCoordinator {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        for text in texts { history.recordText(text) }
        return CommandCoordinator.isolated(history: history, index: inertAppIndex)
    }

    private func browseClipboard(_ coordinator: CommandCoordinator) {
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
    }

    // MARK: - Nothing typed

    @Test func rightInClipboardModeOpensTheSelectedItemsActions() throws {
        let coordinator = makeCoordinator(seededWith: ["older", "newer"])
        browseClipboard(coordinator)
        coordinator.clipboardVM.selectedIndex = 1
        let item = try #require(coordinator.currentClipboardItem)

        coordinator.stepHorizontally(.right)

        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.selectedClipboardItem?.id == item.id)
    }

    @Test func leftFromAClipboardItemsActionsGoesBackToTheBrowser() {
        let coordinator = makeCoordinator(seededWith: ["hello"])
        browseClipboard(coordinator)
        coordinator.stepHorizontally(.right)
        #expect(coordinator.phase == .pickingAction)

        coordinator.stepHorizontally(.left)

        #expect(coordinator.phase == .browsingClipboard)
    }

    @Test func leftInClipboardModeGoesBackToSubjectSearch() {
        let coordinator = makeCoordinator(seededWith: ["hello"])
        browseClipboard(coordinator)

        coordinator.stepHorizontally(.left)

        #expect(coordinator.phase == .searchingSubject)
    }

    // MARK: - A typed Query moves the Phase all the same

    @Test func aTypedQueryInClipboardModeStillMovesThePhase() {
        let coordinator = makeCoordinator(seededWith: ["apple pie", "banana"])
        browseClipboard(coordinator)
        coordinator.clipboardVM.searchText = "apple"

        coordinator.stepHorizontally(.right)
        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.selectedClipboardItem?.content == "apple pie")

        coordinator.stepHorizontally(.left)
        #expect(coordinator.phase == .browsingClipboard)
    }

    @Test func aTypedQueryInTheActionPhaseStillMovesThePhase() {
        let coordinator = makeCoordinator(seededWith: ["hello"])
        browseClipboard(coordinator)
        coordinator.advancePhase()
        #expect(coordinator.phase == .pickingAction)
        coordinator.actionVM.searchText = "co"

        coordinator.stepHorizontally(.left)

        #expect(coordinator.phase == .browsingClipboard)
    }

    // MARK: - The Emoji grid takes them first

    @Test func theEmojiGridWalksCells() {
        let coordinator = makeCoordinator()
        coordinator.enterEmojiMode()
        coordinator.emojiVM.selectedIndex = 4

        coordinator.stepHorizontally(.right)
        #expect(coordinator.emojiVM.selectedIndex == 5)
        coordinator.stepHorizontally(.left)
        #expect(coordinator.emojiVM.selectedIndex == 4)
        coordinator.stepHorizontally(.left)
        #expect(coordinator.emojiVM.selectedIndex == 3)

        #expect(coordinator.phase == .browsingEmoji, "the Phase never moved")
    }
}
