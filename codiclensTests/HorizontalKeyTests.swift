import Testing
@testable import codiclens

/// Left/Right and Ctrl+Left/Right, paired with Ctrl+H/L: the grid first, then
/// the Phase. A bare arrow moves the Phase only with nothing typed in it, so a
/// Query keeps its caret.
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

    // MARK: - Plain arrows

    @Test func rightWithNothingTypedInClipboardModeOpensTheSelectedItemsActions() throws {
        let coordinator = makeCoordinator(seededWith: ["older", "newer"])
        browseClipboard(coordinator)
        coordinator.clipboardVM.selectedIndex = 1
        let item = try #require(coordinator.currentClipboardItem)

        #expect(coordinator.arrowHorizontally(.right))

        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.selectedClipboardItem?.id == item.id)
    }

    @Test func leftFromAClipboardItemsActionsGoesBackToTheBrowser() {
        let coordinator = makeCoordinator(seededWith: ["hello"])
        browseClipboard(coordinator)
        coordinator.arrowHorizontally(.right)
        #expect(coordinator.phase == .pickingAction)

        #expect(coordinator.arrowHorizontally(.left))

        #expect(coordinator.phase == .browsingClipboard)
    }

    @Test func leftWithNothingTypedInClipboardModeGoesBackToSubjectSearch() {
        let coordinator = makeCoordinator(seededWith: ["hello"])
        browseClipboard(coordinator)

        #expect(coordinator.arrowHorizontally(.left))

        #expect(coordinator.phase == .searchingSubject)
    }

    @Test func aTypedQueryKeepsTheArrowsForItsCaret() {
        let coordinator = makeCoordinator(seededWith: ["apple pie", "banana"])
        browseClipboard(coordinator)
        coordinator.clipboardVM.searchText = "apple"

        #expect(coordinator.arrowHorizontally(.right) == false)
        #expect(coordinator.arrowHorizontally(.left) == false)

        #expect(coordinator.phase == .browsingClipboard)
        #expect(coordinator.currentQuery == "apple")
    }

    @Test func aTypedQueryInTheActionPhaseKeepsTheArrowsToo() {
        let coordinator = makeCoordinator(seededWith: ["hello"])
        browseClipboard(coordinator)
        coordinator.advancePhase()
        coordinator.actionVM.searchText = "co"

        #expect(coordinator.arrowHorizontally(.left) == false)

        #expect(coordinator.phase == .pickingAction)
    }

    @Test func theEmojiGridStillWalksCells() {
        let coordinator = makeCoordinator()
        coordinator.enterEmojiMode()
        coordinator.emojiVM.selectedIndex = 4

        #expect(coordinator.arrowHorizontally(.right))
        #expect(coordinator.emojiVM.selectedIndex == 5)
        #expect(coordinator.arrowHorizontally(.left))
        #expect(coordinator.emojiVM.selectedIndex == 4)

        #expect(coordinator.phase == .browsingEmoji, "the Phase never moved")
    }

    @Test func anOpenEditorKeepsTheArrows() {
        let coordinator = makeCoordinator(seededWith: ["hello"])
        browseClipboard(coordinator)
        coordinator.toggleTextSubjectEdit()
        #expect(coordinator.isEditingTextSubject)

        #expect(coordinator.arrowHorizontally(.right) == false)
        #expect(coordinator.arrowHorizontally(.left) == false)

        #expect(coordinator.phase == .browsingClipboard)
    }

    // MARK: - Control arrows, the same as Ctrl+H/L

    @Test func controlArrowsMoveThePhaseEvenWithAQuery() {
        let coordinator = makeCoordinator(seededWith: ["apple pie", "banana"])
        browseClipboard(coordinator)
        coordinator.clipboardVM.searchText = "apple"

        coordinator.stepHorizontally(.right)
        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.selectedClipboardItem?.content == "apple pie")

        coordinator.stepHorizontally(.left)
        #expect(coordinator.phase == .browsingClipboard)
    }

    @Test func controlArrowsWalkTheEmojiGridFirst() {
        let coordinator = makeCoordinator()
        coordinator.enterEmojiMode()
        coordinator.emojiVM.selectedIndex = 4

        coordinator.stepHorizontally(.left)

        #expect(coordinator.emojiVM.selectedIndex == 3)
        #expect(coordinator.phase == .browsingEmoji)
    }
}
