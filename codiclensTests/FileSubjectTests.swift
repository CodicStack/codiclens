import AppKit
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// The two ways a file becomes a Subject — a typed path, and a promoted Target
/// — and the Action lists that were dead branches until they did. See
/// `docs/adr/0008-a-file-can-be-a-subject.md`.
@MainActor
struct FileSubjectTests {

    // MARK: - Fixtures

    private func makeCoordinator() -> (CommandCoordinator, RecordingEffectRunner) {
        let runner = RecordingEffectRunner()
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        return (CommandCoordinator(runner: runner, history: history, index: inertAppIndex), runner)
    }

    private func selectAction(_ name: String, in coordinator: CommandCoordinator) throws {
        let index = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == name },
            "no action named \(name)"
        )
        coordinator.actionVM.selectedIndex = index
    }

    /// A directory holding one `note.txt`. Removed by the caller.
    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(
            to: root.appendingPathComponent("note.txt"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    private func finderSubject() -> Subject {
        Subject(
            displayName: "Finder",
            path: "/System/Library/CoreServices/Finder.app",
            url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
            icon: NSImage(),
            kind: .app(bundleIdentifier: "com.apple.finder", isRunning: true)
        )
    }

    // MARK: - Path Subject

    @Test func anAbsolutePathToAFileResolvesToOneFileSubject() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (coordinator, _) = makeCoordinator()

        coordinator.subjectVM.searchText = root.appendingPathComponent("note.txt").path

        #expect(coordinator.subjectVM.results.count == 1, "exactly one Result, never a listing")
        let subject = try #require(coordinator.subjectVM.results.first)
        guard case .file(let contentType) = subject.kind else {
            Issue.record("expected a file Subject, got \(subject.kind)")
            return
        }
        #expect(contentType.conforms(to: .plainText))
        #expect(subject.displayName == "note.txt")
    }

    @Test func anAbsolutePathToADirectoryResolvesToAFolderSubject() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (coordinator, _) = makeCoordinator()

        coordinator.subjectVM.searchText = root.path

        #expect(coordinator.subjectVM.results.count == 1, "a folder, not its contents")
        guard case .folder = try #require(coordinator.subjectVM.results.first).kind else {
            Issue.record("expected a folder Subject")
            return
        }
    }

    /// `~` is expanded, and Enter on the folder opens it in Finder — the
    /// `defaultEffects` path `.folder` already had.
    @Test func aTildePathResolvesToTheHomeFolderAndOpensIt() throws {
        let (coordinator, _) = makeCoordinator()

        coordinator.subjectVM.searchText = "~"

        let subject = try #require(coordinator.subjectVM.results.first)
        guard case .folder = subject.kind else {
            Issue.record("expected a folder Subject for ~")
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        #expect(subject.url == home)
        #expect(coordinator.submit() == [.hide, .open(home)])
    }

    /// A path that names nothing produces no Result and the Panel shakes. Same
    /// no-match, same shake — no second mechanism.
    @Test func aPathThatDoesNotExistProducesNoResultAndShakes() {
        let (coordinator, _) = makeCoordinator()

        coordinator.subjectVM.searchText = "/no/such/place/zzqqzz"

        #expect(coordinator.subjectVM.results.isEmpty)
        #expect(coordinator.subjectVM.hasNoMatch)
        #expect(coordinator.hasNoSubjectMatch, "the state the Panel shakes about")
        #expect(coordinator.submit().isEmpty, "nothing to act on")
    }

    /// A path is not prose. Text Mode fires on zero *app* matches, and a path
    /// Query never asks the Index anything.
    @Test func aPathQueryNeverTripsTextMode() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (coordinator, _) = makeCoordinator()

        coordinator.subjectVM.searchText = root.path
        #expect(!coordinator.isTextMode)

        coordinator.subjectVM.searchText = "/no/such/place/zzqqzz"
        #expect(!coordinator.isTextMode, "an unresolved path is not text either")
    }

    /// The Index gates do not move for a path, in either direction. `/` and `~`
    /// cannot collide with an app name, so `isIndexReady` and
    /// `canReportNoResults` are exactly what they were.
    @Test func aPathQueryLeavesTheIndexGatesAlone() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (coordinator, _) = makeCoordinator()

        coordinator.subjectVM.searchText = root.path

        #expect(!coordinator.subjectVM.isIndexReady, "still no Index, and it was not consulted")
        #expect(!coordinator.canReportNoResults, "the Subject gate is the Index's, unchanged")
        #expect(!coordinator.hasNoSubjectMatch, "the path resolved")
    }

    /// Only `/` and `~`. A leading dot is an ordinary character in an app name.
    @Test(arguments: ["/", "~", "/tmp", "~/Downloads"])
    func slashAndTildeArePaths(query: String) {
        #expect(PathSubject.isPath(query))
    }

    @Test(arguments: [".", "..", "./x", "Safari", "", "note.txt"])
    func nothingElseIsAPath(query: String) {
        #expect(!PathSubject.isPath(query))
    }

    // MARK: - The file and folder Action lists

    @Test func aFileSubjectHasTheFileActions() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (coordinator, _) = makeCoordinator()
        coordinator.subjectVM.searchText = root.appendingPathComponent("note.txt").path

        coordinator.advancePhase()

        let names = coordinator.actionVM.filteredActions.map(\.name)
        #expect(names.first == "Open")
        #expect(names.contains("Reveal in Finder"))
        #expect(names.contains("Copy Path"))
        #expect(names.contains("Move to Trash"))
        #expect(names.contains("Quick Look"))
        #expect(!names.contains("OCR"), "a .txt has no text to read out of it")
    }

    @Test func openingAFileSubjectHidesThenOpensIt() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("note.txt")
        let (coordinator, runner) = makeCoordinator()
        coordinator.subjectVM.searchText = fileURL.path
        coordinator.advancePhase()
        try selectAction("Open", in: coordinator)

        let effects = coordinator.submit()

        #expect(effects == [.hide, .open(fileURL.standardizedFileURL)])
        #expect(runner.recorded == effects)
    }

    @Test func copyingAFolderSubjectsPathCopiesThePath() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (coordinator, _) = makeCoordinator()
        coordinator.subjectVM.searchText = root.path
        coordinator.advancePhase()
        try selectAction("Copy Path", in: coordinator)

        #expect(coordinator.submit() == [
            .hide, .copy(.text(root.standardizedFileURL.path))
        ])
    }

    // MARK: - Use as Subject

    /// Not Finder-only: the Action names one rule — any Target with a URL
    /// becomes the Subject — and a file Subject carries it too.
    @Test func useAsSubjectIsOfferedWhereverTheTargetsAreFilesOrApps() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (coordinator, _) = makeCoordinator()

        #expect(SubjectAction.actions(for: finderSubject())
            .contains { $0.name == "Use as Subject" })

        coordinator.subjectVM.searchText = root.path
        coordinator.advancePhase()
        #expect(coordinator.actionVM.filteredActions.contains { $0.name == "Use as Subject" })
    }

    @Test func useAsSubjectAsksForATargetRatherThanExecuting() throws {
        let (coordinator, runner) = makeCoordinator()
        coordinator.subjectVM.results = [finderSubject()]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        try selectAction("Use as Subject", in: coordinator)

        #expect(coordinator.submit().isEmpty, "nothing runs; it wants a Target")
        #expect(runner.recorded.isEmpty)
        #expect(coordinator.phase == .pickingTarget)
    }

    /// Picking the Target promotes it: the Subject becomes the file, the Phase
    /// lands on Actions, and the Card row drops from three Cards to two.
    @Test func promotingAFileTargetLandsOnItsActions() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("note.txt")
        let (coordinator, runner) = makeCoordinator()
        coordinator.subjectVM.results = [finderSubject()]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        try selectAction("Use as Subject", in: coordinator)
        _ = coordinator.submit()
        #expect(coordinator.cardCount == 3)

        coordinator.targetVM.filteredTargets = [ActionTarget(
            name: "note.txt", icon: NSImage(), url: fileURL, sharingService: nil
        )]
        coordinator.targetVM.selectedIndex = 0

        #expect(coordinator.submit().isEmpty, "promotion executes nothing")
        #expect(runner.recorded.isEmpty)
        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.cardCount == 2)

        let subject = try #require(coordinator.selectedSubject)
        guard case .file(let contentType) = subject.kind else {
            Issue.record("expected the promoted file as the Subject, got \(subject.kind)")
            return
        }
        #expect(contentType.conforms(to: .plainText))
        #expect(subject.url == fileURL.standardizedFileURL)
        #expect(coordinator.actionVM.filteredActions.first?.name == "Open")
    }

    /// A Target with nothing behind it cannot be promoted, and must not leave
    /// the Phase half-moved.
    @Test func aTargetWithNoURLIsNotPromoted() throws {
        let (coordinator, _) = makeCoordinator()
        coordinator.subjectVM.results = [finderSubject()]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        try selectAction("Use as Subject", in: coordinator)
        _ = coordinator.submit()

        coordinator.targetVM.filteredTargets = [ActionTarget(
            name: "Nowhere", icon: NSImage(), url: nil, sharingService: nil
        )]
        coordinator.targetVM.selectedIndex = 0

        #expect(coordinator.submit().isEmpty)
        #expect(coordinator.phase == .pickingTarget)
    }
}
