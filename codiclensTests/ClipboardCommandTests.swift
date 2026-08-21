import AppKit
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// Clipboard entries are subjects now, so they go through the same execution
/// table as apps, files and text. These tests drive the browser end to end.
@MainActor
struct ClipboardCommandTests {

    private func makeCoordinator(
        seededWith texts: [String] = []
    ) -> (CommandCoordinator, RecordingEffectRunner, ClipboardHistory) {
        useInertAppIndex()
        let runner = RecordingEffectRunner()
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        for text in texts {
            history.recordText(text)
        }
        let coordinator = CommandCoordinator(runner: runner, history: history)
        return (coordinator, runner, history)
    }

    /// Opens the clipboard browser with the first entry selected.
    private func browse(_ coordinator: CommandCoordinator) {
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
    }

    private func selectAction(_ name: String, in coordinator: CommandCoordinator) throws {
        let index = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == name },
            "no action named \(name)"
        )
        coordinator.actionVM.selectedIndex = index
    }

    // MARK: - Pasting

    @Test func enterOnAnEntryPastesIt() {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)

        #expect(coordinator.submit() == [.paste(.text("hello"))])
    }

    @Test func pastingMovesTheEntryToTheTop() {
        let (coordinator, _, history) = makeCoordinator(seededWith: ["oldest", "newest"])
        browse(coordinator)
        coordinator.clipboardVM.selectedIndex = 1   // "oldest"

        coordinator.submit()

        #expect(history.items.map(\.content) == ["oldest", "newest"])
    }

    /// Pasting must not be preceded by `.hide`: dismissing the panel clears the
    /// app to hand activation back to, and the paste would land in the wrong place.
    @Test func pastingNeverHidesFirst() throws {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Paste", in: coordinator)

        #expect(coordinator.submit() == [.paste(.text("hello"))])
    }

    // MARK: - Actions

    @Test func copyingAnEntryHidesAndWritesThePasteboard() throws {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Copy", in: coordinator)

        #expect(coordinator.submit() == [.hide, .copy(.text("hello"))])
    }

    @Test func typingAnEntrySynthesisesKeystrokes() throws {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Type Text", in: coordinator)

        #expect(coordinator.submit() == [.typeText("hello")])
    }

    @Test func savingTextOffersAPlainTextFile() throws {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Save as File…", in: coordinator)

        #expect(coordinator.submit() == [.savePanel(
            data: Data("hello".utf8), fileName: "untitled.txt", contentType: .plainText
        )])
    }

    @Test func deletingRemovesTheEntryAndReturnsToTheBrowser() throws {
        let (coordinator, _, history) = makeCoordinator(seededWith: ["keep", "drop"])
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Delete from History", in: coordinator)

        #expect(coordinator.submit().isEmpty)
        #expect(history.items.map(\.content) == ["keep"])
        #expect(coordinator.phase == .browsingClipboard)
    }

    @Test func countingShowsTheResultWithoutLeavingThePanel() throws {
        let (coordinator, runner, _) = makeCoordinator(seededWith: ["a b c"])
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Count Words", in: coordinator)

        #expect(coordinator.submit().isEmpty)
        #expect(runner.recorded.isEmpty)
        #expect(coordinator.phase == .showingResult("3 words"))
    }

    // MARK: - Transforms

    @Test func transformingAnEntryRewritesItInHistory() throws {
        let (coordinator, _, history) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("UPPERCASE", in: coordinator)

        #expect(coordinator.submit().isEmpty)
        #expect(history.items.map(\.content) == ["HELLO"])
        #expect(coordinator.phase == .browsingClipboard, "stays in the browser")
    }

    /// The same transform on a text subject chains instead of rewriting history —
    /// the one place the merged table still branches on subject kind.
    @Test func transformingTextChainsInsteadOfRewriting() throws {
        let (coordinator, _, history) = makeCoordinator(seededWith: ["untouched"])
        coordinator.subjectVM.results = [Subject(text: "hello")]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        try selectAction("UPPERCASE", in: coordinator)

        #expect(coordinator.submit().isEmpty)
        #expect(history.items.map(\.content) == ["untouched"])
        #expect(coordinator.phase == .pickingAction)
    }

    // MARK: - Images

    @Test func imageEntriesOfferImageActionsOnly() {
        let (coordinator, _, history) = makeCoordinator()
        history.recordImage(Data([0x89, 0x50]))
        browse(coordinator)
        coordinator.advancePhase()

        let names = coordinator.actionVM.filteredActions.map(\.name)
        #expect(names.contains("Save Image…"))
        #expect(names.contains("Open in Preview"))
        #expect(names.contains("Type Text") == false, "images can't be typed")
        #expect(names.contains("UPPERCASE") == false, "images can't be transformed")
    }

    @Test func textEntriesOfferTextActionsOnly() {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()

        let names = coordinator.actionVM.filteredActions.map(\.name)
        #expect(names.contains("Type Text"))
        #expect(names.contains("UPPERCASE"))
        #expect(names.contains("Save Image…") == false)
    }

    @Test func savingAnImageOffersThePNG() throws {
        let (coordinator, _, history) = makeCoordinator()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        history.recordImage(png)
        browse(coordinator)
        coordinator.advancePhase()
        try selectAction("Save Image…", in: coordinator)

        let effects = coordinator.submit()
        guard case .savePanel(let data, _, let type) = try #require(effects.first) else {
            Issue.record("expected a save panel")
            return
        }
        #expect(data == png)
        #expect(type == .png)
    }

    // MARK: - Retreating

    @Test func retreatingFromAClipboardActionReturnsToTheBrowser() {
        let (coordinator, _, _) = makeCoordinator(seededWith: ["hello"])
        browse(coordinator)
        coordinator.advancePhase()
        #expect(coordinator.phase == .pickingAction)

        coordinator.retreatPhase()

        #expect(coordinator.phase == .browsingClipboard)
    }
}
