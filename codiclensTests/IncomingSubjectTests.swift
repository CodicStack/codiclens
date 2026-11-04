import AppKit
import Testing
@testable import codiclens

/// **Incoming Subjects**: files and folders sent from Finder, and text sent
/// from another app, standing as a Last Subject stands. `PanelController`
/// shows the Panel, which is `reset()`, and then hands them in; here the
/// coordinator is handed them directly, in whatever state it is in.
@MainActor
struct IncomingSubjectTests {

    private struct Fixture {
        let root: URL
        let coordinator: CommandCoordinator
        let history: ClipboardHistory

        func file(_ name: String) -> URL { root.appendingPathComponent(name) }
        var inbox: URL { root.appendingPathComponent("Inbox", isDirectory: true) }
    }

    /// A folder holding `a.txt`, `b.txt`, `c.txt` and an `Inbox` folder.
    private func makeFixture(clipboard: [String] = []) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-incoming-\(UUID().uuidString)")
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Inbox", isDirectory: true),
            withIntermediateDirectories: true
        )
        for name in ["a.txt", "b.txt", "c.txt"] {
            try name.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        for text in clipboard { history.recordText(text) }
        let coordinator = CommandCoordinator.isolated(history: history)
        return Fixture(root: root, coordinator: coordinator, history: history)
    }

    /// An app on every Mac, read and never launched.
    private let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    private func selectAction(_ name: String, _ coordinator: CommandCoordinator) throws {
        coordinator.actionVM.selectedIndex = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == name },
            "no Action named \(name)"
        )
    }

    // MARK: - Files

    @Test func theFirstOfSeveralFilesStandsAndTheCardSaysHowManyCame() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.reset()

        coordinator.receiveIncoming(urls: [fixture.file("a.txt"), fixture.file("b.txt"), fixture.file("c.txt")])

        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.cardCount == 1)
        #expect(coordinator.standingSubject?.url == fixture.file("a.txt"))
        #expect(coordinator.subjectVM.searchText.isEmpty, "the Query is empty")
        #expect(coordinator.currentResults.isEmpty, "it is not a Result")
        #expect(coordinator.incomingCount == 3)
    }

    @Test func oneFileSentSaysNothingAboutHowMany() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.coordinator.receiveIncoming(urls: [fixture.file("a.txt")])

        #expect(fixture.coordinator.incomingCount == 1)
    }

    @Test func enterOpensIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.coordinator.receiveIncoming(urls: [fixture.file("a.txt")])

        #expect(fixture.coordinator.submit() == [.hide, .open(fixture.file("a.txt"))])
    }

    @Test func tabOpensItsActionsWithTheCountAndShiftTabComesBack() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.receiveIncoming(urls: [fixture.file("a.txt"), fixture.file("b.txt")])

        coordinator.advancePhase()
        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.selectedSubject?.url == fixture.file("a.txt"))
        #expect(coordinator.actionVM.filteredActions.first?.name == "Open")
        #expect(coordinator.incomingCount == 2, "still the Incoming Subject")

        coordinator.retreatPhase()
        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.standingSubject?.url == fixture.file("a.txt"))
        #expect(coordinator.incomingCount == 2)
    }

    @Test func aFolderStands() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.coordinator.receiveIncoming(urls: [fixture.inbox])

        guard case .folder? = fixture.coordinator.standingSubject?.kind else {
            Issue.record("expected a folder, got \(String(describing: fixture.coordinator.standingSubject?.kind))")
            return
        }
    }

    @Test func theFirstKeystrokeStartsANewQueryAndTheCountGoes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.receiveIncoming(urls: [fixture.file("a.txt"), fixture.file("b.txt")])

        coordinator.acceptTypedText("c")

        #expect(coordinator.standingSubject == nil)
        #expect(coordinator.currentSearchText == "c")
        #expect(coordinator.incomingCount == 0)
    }

    /// Sent in counts as acted on: dismissed with Escape, it stands next time,
    /// as the Last Subject, without the count.
    @Test func dismissedItStandsAgainNextTime() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.receiveIncoming(urls: [fixture.file("a.txt"), fixture.file("b.txt")])
        #expect(!coordinator.handleEscape(), "Escape closes the Panel")

        coordinator.reset()

        #expect(coordinator.standingSubject?.url == fixture.file("a.txt"))
        #expect(coordinator.lastSubject?.url == fixture.file("a.txt"))
        #expect(coordinator.incomingCount == 0)
    }

    @Test func nothingThatResolvesLeavesThePanelEmpty() throws {
        let fixture = try makeFixture(clipboard: ["hello"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
        coordinator.submit()
        coordinator.reset()
        #expect(coordinator.standingSubject != nil, "the Last Subject stood as the Panel opened")

        coordinator.receiveIncoming(urls: [fixture.file("gone.txt")])

        #expect(coordinator.standingSubject == nil)
        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.subjectVM.searchText.isEmpty)
        #expect(coordinator.currentResults.isEmpty)
        #expect(!coordinator.hasNoSubjectMatch, "no shake")
        #expect(coordinator.incomingCount == 0)

        coordinator.receiveIncoming(urls: [])
        #expect(coordinator.standingSubject == nil)
    }

    // MARK: - Mid-command

    @Test func sentMidTargetPhaseItDropsTheCommand() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = fixture.file("a.txt").path
        coordinator.advancePhase()
        try selectAction("Move To…", coordinator)
        coordinator.advancePhase()
        #expect(coordinator.phase == .pickingTarget)

        coordinator.receiveIncoming(urls: [fixture.file("b.txt")])

        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.cardCount == 1)
        #expect(coordinator.selectedAction == nil)
        #expect(coordinator.standingSubject?.url == fixture.file("b.txt"))
        #expect(coordinator.subjectVM.searchText.isEmpty, "the path Query is gone")
    }

    /// A Move on disk when the file arrives has its answer dropped: the
    /// Panel is on the Incoming Subject now.
    @Test func anAnswerToTheDroppedCommandIsDropped() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = fixture.file("a.txt").path
        coordinator.advancePhase()
        try selectAction("Move To…", coordinator)
        coordinator.advancePhase()
        // The first folder offered. Nothing moves until the test moves it:
        // the runner only records.
        #expect(!coordinator.targetVM.filteredTargets.isEmpty)
        guard case .fileOperation(_, let generation)? = coordinator.submit().first else {
            Issue.record("expected a file operation")
            return
        }

        coordinator.receiveIncoming(urls: [fixture.file("b.txt")])
        coordinator.receiveFileOperation(.success(fixture.inbox.appendingPathComponent("a.txt")), generation: generation)

        #expect(!coordinator.isFileOperationInFlight)
        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.standingSubject?.url == fixture.file("b.txt"))
    }

    @Test func sentWhileTextIsBeingEditedItClosesTheEditor() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.acceptTypedText("draft")
        coordinator.toggleTextSubjectEdit()
        #expect(coordinator.isEditingTextSubject)

        coordinator.receiveIncoming(urls: [fixture.file("a.txt")])

        #expect(!coordinator.isEditingTextSubject)
        #expect(coordinator.standingSubject?.url == fixture.file("a.txt"))
    }

    // MARK: - Apps

    /// An app stands as it came, and is acted on as one, but never becomes
    /// the Last Subject: the next open has nothing standing.
    @Test func anAppStandsButIsNotTheLastSubject() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator

        coordinator.receiveIncoming(urls: [calculator])

        guard case .app? = coordinator.standingSubject?.kind else {
            Issue.record("expected an app, got \(String(describing: coordinator.standingSubject?.kind))")
            return
        }
        #expect(coordinator.lastSubject == nil)
        coordinator.advancePhase()
        #expect(coordinator.actionVM.filteredActions.first?.name == "Open")
        coordinator.retreatPhase()
        #expect(coordinator.submit() == [.hide, .open(calculator)])

        coordinator.reset()

        #expect(coordinator.standingSubject == nil)
        #expect(coordinator.lastSubject == nil)
    }

    /// Sent in counts as acted on, and acting on an app ends the Last Subject.
    @Test func anAppSentInEndsTheLastSubject() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.receiveIncoming(urls: [fixture.file("a.txt")])
        coordinator.reset()

        coordinator.receiveIncoming(urls: [calculator])
        coordinator.reset()

        #expect(coordinator.standingSubject == nil)
    }

    // MARK: - Text

    @Test func textStandsAndEnterCopiesIt() throws {
        let coordinator = CommandCoordinator.isolated()
        coordinator.reset()

        coordinator.receiveIncoming(text: "from Safari")

        guard case .text("from Safari")? = coordinator.standingSubject?.kind else {
            Issue.record("expected the text, got \(String(describing: coordinator.standingSubject?.kind))")
            return
        }
        #expect(coordinator.cardCount == 1)
        #expect(coordinator.incomingCount == 1)
        #expect(coordinator.submit() == [.paste(.text("from Safari"))])

        coordinator.reset()
        guard case .text("from Safari")? = coordinator.standingSubject?.kind else {
            Issue.record("expected it to stand again, got \(String(describing: coordinator.standingSubject?.kind))")
            return
        }
    }

    @Test func tabOpensTextActions() throws {
        let coordinator = CommandCoordinator.isolated()
        coordinator.receiveIncoming(text: "from Safari")

        coordinator.advancePhase()

        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.actionVM.filteredActions.contains { $0.name == "UPPERCASE" })
    }

    @Test func whitespaceIsIgnored() throws {
        let coordinator = CommandCoordinator.isolated()
        coordinator.acceptTypedText("saf")

        coordinator.receiveIncoming(text: " \n\t ")

        #expect(coordinator.standingSubject == nil)
        #expect(coordinator.currentSearchText == "saf", "nothing changed")
    }

    // MARK: - Backspace and Actions' results

    /// Backspace takes an Incoming Subject away, and it does not stand again
    /// when the Panel next opens.
    @Test func backspaceRemovesTheIncomingSubject() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.receiveIncoming(urls: [fixture.file("a.txt"), fixture.file("b.txt")])

        #expect(coordinator.removeStandingSubject())

        #expect(coordinator.standingSubject == nil)
        #expect(coordinator.incomingCount == 0)
        coordinator.reset()
        #expect(coordinator.standingSubject == nil)
    }

    /// An app sent in stands without being remembered; Backspace ends it all
    /// the same.
    @Test func backspaceRemovesAnIncomingApp() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.receiveIncoming(urls: [calculator])
        guard case .app? = coordinator.standingSubject?.kind else {
            Issue.record("expected Calculator standing")
            return
        }

        #expect(coordinator.removeStandingSubject())
        #expect(coordinator.standingSubject == nil)
    }

    /// Compressing a file sent in ends the Incoming Subject: the zip stands
    /// in its place, and the Card no longer counts what was sent.
    @Test func whatAnActionMakesOfItStandsInItsPlace() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.receiveIncoming(urls: [fixture.file("a.txt"), fixture.file("b.txt")])
        coordinator.advancePhase()
        try selectAction("Compress", coordinator)
        guard case .fileOperation(_, let generation)? = coordinator.submit().first else {
            Issue.record("expected a file operation")
            return
        }

        let zip = fixture.file("a.txt.zip")
        try Data("PK".utf8).write(to: zip)
        coordinator.receiveFileOperation(.success(zip), generation: generation)

        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.standingSubject?.url == zip)
        #expect(coordinator.incomingCount == 0)
    }
}
