import AppKit
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// Move To…, Copy To…, Rename, Compress and Copy File on a file or folder
/// Subject, through the coordinator with a recording runner: which Effects
/// leave, and what the Subject becomes when the answer comes back. Nothing here
/// touches the disk except to stand files up for a Path Subject to resolve;
/// `FileOperationTests` does the real work.
@MainActor
struct FileActionCommandTests {

    // MARK: - Fixtures

    private struct Fixture {
        let root: URL
        let coordinator: CommandCoordinator
        let runner: RecordingEffectRunner
        let sources: SourceStore

        var note: URL { root.appendingPathComponent("note.txt").standardizedFileURL }
        var inbox: URL { root.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL }
    }

    /// A folder holding `note.txt` and an `Inbox` folder, the Inbox a folder
    /// Source of a throwaway `SourceStore`.
    private func makeFixture(searchFiles: @escaping FileIndex.Search = { _ in [] }) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-file-actions-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let defaults = ThrowawayDefaults()
        defaults.set([String](), forKey: "codiclens.sources.folders")
        let sources = SourceStore(defaults: defaults)
        sources.addFolder(inbox)

        let runner = RecordingEffectRunner()
        let coordinator = CommandCoordinator.isolated(runner: runner, sources: sources, searchFiles: searchFiles)
        return Fixture(root: root, coordinator: coordinator, runner: runner, sources: sources)
    }

    /// Stands the file or folder at `url` as the Subject, on the Action Phase.
    private func choose(_ url: URL, in coordinator: CommandCoordinator) {
        coordinator.subjectVM.searchText = url.path
        coordinator.advancePhase()
    }

    private func selectAction(_ name: String, in coordinator: CommandCoordinator) throws {
        coordinator.actionVM.selectedIndex = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == name },
            "no Action named \(name)"
        )
    }

    private func selectTarget(_ url: URL, in coordinator: CommandCoordinator) throws {
        coordinator.targetVM.selectedIndex = try #require(
            coordinator.targetVM.filteredTargets.firstIndex { $0.url?.standardizedFileURL == url },
            "no Target at \(url.path)"
        )
    }

    private func generation(of effects: [Effect]) throws -> Int {
        guard case .fileOperation(_, let generation) = try #require(effects.first) else {
            Issue.record("expected a file operation, got \(effects)")
            return -1
        }
        return generation
    }

    // MARK: - Order

    private static let fileOrder = [
        "Open", "Quick Look", "Reveal in Finder", "Share…", "Open With…", "Paste File", "Copy File",
        "Copy Path", "Move To…", "Copy To…", "Rename", "Compress", "Use as Subject", "Move to Trash",
    ]

    private func subject(_ name: String, kind: SubjectKind) -> Subject {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return Subject(displayName: name, path: url.path, url: url, icon: NSImage(), kind: kind)
    }

    @Test func fileActionsRunMostUsedFirstWithMoveToTrashLast() {
        let names = SubjectAction.actions(for: subject("note.txt", kind: .file(contentType: .plainText))).map(\.name)
        #expect(names == Self.fileOrder)
    }

    @Test func aFolderHasTheSameListAsAFile() {
        let names = SubjectAction.actions(for: subject("Projects", kind: .folder)).map(\.name)
        #expect(names == Self.fileOrder)
    }

    @Test func imageActionsComeStraightAfterQuickLook() {
        let names = SubjectAction.actions(for: subject("photo.png", kind: .file(contentType: .png))).map(\.name)
        var expected = Self.fileOrder
        expected.insert(contentsOf: ["OCR", "Rotate Left", "Rotate Right", "Open in Preview"], at: 2)
        #expect(names == expected)
    }

    @Test func audioAndVideoGetTranscribeStraightAfterQuickLook() {
        let audio = SubjectAction.actions(for: subject("memo.m4a", kind: .file(contentType: .mpeg4Audio))).map(\.name)
        let video = SubjectAction.actions(for: subject("clip.mov", kind: .file(contentType: .quickTimeMovie))).map(\.name)
        var expected = Self.fileOrder
        expected.insert("Transcribe", at: 2)
        #expect(audio == expected)
        #expect(video == expected)
    }

    @Test func clipboardItemsKeepTheirOrderWithQuickLookMovedUp() {
        let text = SubjectAction.actions(for: Subject(clipboardItem: ClipboardItem(content: "hi"), imageURL: nil))
            .map(\.name)
        let image = SubjectAction.actions(for: Subject(clipboardItem: ClipboardItem(imageFileName: "i.png"), imageURL: nil))
            .map(\.name)

        #expect(Array(text.prefix(4)) == ["Paste", "Copy", "Quick Look", "Paste as Plain Text"])
        #expect(text.last == "Delete from History")
        #expect(image == [
            "Paste", "Copy", "Quick Look", "Paste as Plain Text", "OCR", "Save Image…", "Open in Preview",
            "Rotate Left", "Rotate Right", "Copy Path", "Share…", "Delete from History",
        ])
    }

    /// A Clipboard Image's stored PNG is not a file of the user's.
    @Test func noClipboardItemOrAppIsMovedRenamedOrZipped() {
        let fileOnly: Set = ["Paste File", "Copy File", "Move To…", "Copy To…", "Rename", "Compress"]
        let image = Subject(clipboardItem: ClipboardItem(imageFileName: "i.png"), imageURL: nil)
        let app = subject("Safari.app", kind: .app(bundleIdentifier: "com.apple.Safari", isRunning: false))

        #expect(fileOnly.isDisjoint(with: SubjectAction.actions(for: image).map(\.name)))
        #expect(fileOnly.isDisjoint(with: SubjectAction.actions(for: app).map(\.name)))
    }

    @Test func finderShowsQuickLookRightAfterOpenFile() {
        let finder = subject("Finder.app", kind: .app(bundleIdentifier: "com.apple.finder", isRunning: true))
        #expect(SubjectAction.actions(for: finder).map(\.name) == [
            "Open File", "Quick Look", "Reveal in Finder", "Copy Path", "Move to Trash", "Use as Subject",
        ])
    }

    // MARK: - Copy File

    @Test func copyFilePutsTheFileItselfOnThePasteboardAndHides() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        choose(fixture.note, in: fixture.coordinator)
        try selectAction("Copy File", in: fixture.coordinator)

        #expect(fixture.coordinator.submit() == [.hide, .copy(.fileURL(fixture.note))])
    }

    @Test func pasteFilePastesTheFileItselfIntoThePreviousApp() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        choose(fixture.note, in: fixture.coordinator)
        try selectAction("Paste File", in: fixture.coordinator)

        #expect(fixture.coordinator.submit() == [.paste(.fileURL(fixture.note))])
    }

    // MARK: - Move To… and Copy To…

    @Test func moveToListsTheFolderSourcesAndTheCommonFolders() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        choose(fixture.note, in: fixture.coordinator)
        try selectAction("Move To…", in: fixture.coordinator)
        fixture.coordinator.advancePhase()

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let urls = fixture.coordinator.targetVM.filteredTargets.compactMap { $0.url?.standardizedFileURL }
        #expect(fixture.coordinator.phase == .pickingTarget)
        #expect(urls.first == fixture.inbox, "the folder Source, before the common folders")
        #expect(urls.contains(home))
        #expect(Set(urls).count == urls.count, "each folder once")
    }

    @Test func enterOnAFolderMovesBehindTheSeamWithoutHiding() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        choose(fixture.note, in: coordinator)
        try selectAction("Move To…", in: coordinator)
        coordinator.advancePhase()
        try selectTarget(fixture.inbox, in: coordinator)

        let effects = coordinator.submit()
        let generation = try generation(of: effects)

        #expect(effects == [.fileOperation(.move(fixture.note, into: fixture.inbox), generation: generation)])
        #expect(fixture.runner.recorded == effects)
        #expect(coordinator.isFileOperationInFlight)
        #expect(coordinator.fileOperationNote == "Moving…")
        #expect(coordinator.submit().isEmpty, "a second Enter does nothing while the first is on disk")
    }

    /// The command is done, so the moved file stands in Subject search as a
    /// Last Subject stands: one Card, the Query empty, Enter opens it and Tab
    /// gives its Actions.
    @Test func aMovedFileStandsWhereItLanded() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        choose(fixture.note, in: coordinator)
        try selectAction("Move To…", in: coordinator)
        coordinator.advancePhase()
        try selectTarget(fixture.inbox, in: coordinator)
        let generation = try generation(of: coordinator.submit())

        let landed = fixture.inbox.appendingPathComponent("note.txt")
        try FileManager.default.moveItem(at: fixture.note, to: landed)
        coordinator.receiveFileOperation(.success(landed), generation: generation)

        #expect(!coordinator.isFileOperationInFlight)
        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.cardCount == 1)
        #expect(coordinator.subjectVM.searchText.isEmpty, "the path that found it was the old Query")
        #expect(coordinator.standingSubject?.url == landed.standardizedFileURL)
        #expect(coordinator.destinationFolders().first == fixture.inbox, "the last destination leads next time")

        coordinator.advancePhase()
        #expect(coordinator.selectedSubject?.url == landed.standardizedFileURL)
        #expect(coordinator.actionVM.filteredActions.first?.name == "Open")
        coordinator.retreatPhase()
        #expect(coordinator.standingSubject?.url == landed.standardizedFileURL, "Shift+Tab comes back to it")
        #expect(coordinator.submit() == [.hide, .open(landed.standardizedFileURL)])
    }

    @Test func copyToSendsACopyAndAFailureShakesWithAShortMessage() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        choose(fixture.note, in: coordinator)
        let subjectBefore = try #require(coordinator.selectedSubject)
        try selectAction("Copy To…", in: coordinator)
        coordinator.advancePhase()
        try selectTarget(fixture.inbox, in: coordinator)

        let effects = coordinator.submit()
        let generation = try generation(of: effects)
        #expect(effects == [.fileOperation(.copy(fixture.note, into: fixture.inbox), generation: generation)])

        coordinator.receiveFileOperation(.failure(.failed), generation: generation)

        #expect(coordinator.fileOperationFailure == "Couldn't copy")
        #expect(coordinator.fileOperationNote == "Couldn't copy")
        #expect(coordinator.selectedSubject?.id == subjectBefore.id, "the Subject is where it was")
        #expect(coordinator.phase == .pickingTarget, "the folder list stays up to try another")

        coordinator.retreatPhase()
        #expect(coordinator.fileOperationFailure == nil, "the message belongs to the Phase it failed in")
    }

    @Test func anAnswerAfterResetIsDropped() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        choose(fixture.note, in: coordinator)
        try selectAction("Move To…", in: coordinator)
        coordinator.advancePhase()
        try selectTarget(fixture.inbox, in: coordinator)
        let generation = try generation(of: coordinator.submit())

        coordinator.reset()
        coordinator.receiveFileOperation(.success(fixture.inbox), generation: generation)

        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.selectedSubject == nil)
        #expect(!coordinator.isFileOperationInFlight)
    }

    @Test func typingInMoveToAddsTheFileIndexsFoldersAndNoFiles() async throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("Projects")
        let hits = [
            FileHit(url: projects, name: "Projects", folder: "/tmp", kind: .folder, score: 0),
            FileHit(url: projects.appendingPathComponent("plan.txt"), name: "plan.txt", folder: "/tmp/Projects", kind: .file, score: 1),
        ]
        let fixture = try makeFixture(searchFiles: { _ in hits })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        choose(fixture.note, in: coordinator)
        try selectAction("Move To…", in: coordinator)
        coordinator.advancePhase()

        coordinator.targetVM.searchText = "proj"
        #expect(coordinator.isSearchInFlight, "Searching…, not No results, until the index answers")
        while coordinator.targetVM.isSearching { try await Task.sleep(for: .milliseconds(5)) }

        let urls = coordinator.targetVM.filteredTargets.compactMap(\.url)
        #expect(urls == [projects.standardizedFileURL])
    }

    // MARK: - Rename

    @Test func renameOpensTheNameEditorWithTheBaseNameSelected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        choose(fixture.note, in: coordinator)
        try selectAction("Rename", in: coordinator)

        #expect(coordinator.submit().isEmpty, "nothing on disk until the editor commits")
        #expect(coordinator.isRenaming)
        #expect(coordinator.renameText == "note.txt")
        #expect(coordinator.renameText[coordinator.renameSelectedRange] == "note")
        #expect(coordinator.phase == .pickingAction)
    }

    @Test func aFoldersWholeNameIsSelected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let dotted = fixture.root.appendingPathComponent("v1.2", isDirectory: true)
        try FileManager.default.createDirectory(at: dotted, withIntermediateDirectories: true)
        let coordinator = fixture.coordinator
        choose(dotted, in: coordinator)
        try selectAction("Rename", in: coordinator)
        coordinator.submit()

        #expect(coordinator.renameText[coordinator.renameSelectedRange] == "v1.2")
    }

    @Test func committingRenamesBehindTheSeamAndATakenNameKeepsTheEditorOpen() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        choose(fixture.note, in: coordinator)
        try selectAction("Rename", in: coordinator)
        coordinator.submit()

        coordinator.renameText = "Inbox"
        let first = coordinator.commitRename()
        let firstGeneration = try generation(of: first)
        #expect(first == [.fileOperation(.rename(fixture.note, to: "Inbox"), generation: firstGeneration)])
        #expect(fixture.runner.recorded == first)

        coordinator.receiveFileOperation(.failure(.nameTaken), generation: firstGeneration)
        #expect(coordinator.isRenaming, "still open, to try another name")
        #expect(coordinator.fileOperationFailure == "Name already taken")

        coordinator.renameText = "memo.txt"
        let second = coordinator.commitRename()
        let secondGeneration = try generation(of: second)
        #expect(coordinator.fileOperationFailure == nil, "cleared as the next try starts")

        let renamed = fixture.root.appendingPathComponent("memo.txt")
        try FileManager.default.moveItem(at: fixture.note, to: renamed)
        coordinator.receiveFileOperation(.success(renamed), generation: secondGeneration)

        #expect(!coordinator.isRenaming)
        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.cardCount == 1)
        #expect(coordinator.standingSubject?.url == renamed.standardizedFileURL)
        #expect(coordinator.standingSubject?.displayName == "memo.txt")
    }

    /// A folder renamed into an app bundle is an app, and an app is never a
    /// Last Subject, so it has nothing to stand as: the Panel stays on its
    /// Actions rather than empty.
    @Test func aRenameThatMakesAnAppStaysOnItsActions() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        choose(fixture.inbox, in: coordinator)
        try selectAction("Rename", in: coordinator)
        coordinator.submit()
        coordinator.renameText = "Inbox.app"
        let generation = try generation(of: coordinator.commitRename())

        let app = fixture.root.appendingPathComponent("Inbox.app", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.inbox, to: app)
        coordinator.receiveFileOperation(.success(app), generation: generation)

        #expect(!coordinator.isRenaming)
        guard case .app? = coordinator.selectedSubject?.kind else {
            Issue.record("expected the app the folder became, got \(String(describing: coordinator.selectedSubject?.kind))")
            return
        }
        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.cardCount == 2)
        #expect(coordinator.standingSubject == nil)
        #expect(coordinator.actionVM.filteredActions.first?.name == "Open")
    }

    @Test func escapeLeavesTheNameAsItWas() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        choose(fixture.note, in: coordinator)
        try selectAction("Rename", in: coordinator)
        coordinator.submit()
        coordinator.renameText = "memo.txt"

        #expect(coordinator.handleEscape(), "Escape is the editor's, not the Panel's")
        #expect(!coordinator.isRenaming)
        #expect(fixture.runner.recorded.isEmpty)
        #expect(coordinator.phase == .pickingAction)
    }

    @Test func anUnchangedNameJustClosesTheEditor() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        choose(fixture.note, in: coordinator)
        try selectAction("Rename", in: coordinator)
        coordinator.submit()

        #expect(coordinator.commitRename().isEmpty)
        #expect(!coordinator.isRenaming)
        #expect(fixture.runner.recorded.isEmpty)
    }

    // MARK: - Compress

    @Test func compressZipsBehindTheSeamAndTheZipBecomesTheSubject() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        choose(fixture.inbox, in: coordinator)
        try selectAction("Compress", in: coordinator)

        let effects = coordinator.submit()
        let generation = try generation(of: effects)
        #expect(effects == [.fileOperation(.compress(fixture.inbox), generation: generation)])
        #expect(!effects.contains(.hide))
        #expect(coordinator.fileOperationNote == "Compressing…")

        let zip = fixture.root.appendingPathComponent("Inbox.zip")
        try Data("PK".utf8).write(to: zip)
        coordinator.receiveFileOperation(.success(zip), generation: generation)

        #expect(coordinator.phase == .searchingSubject)
        #expect(coordinator.standingSubject?.url == zip.standardizedFileURL)
        coordinator.advancePhase()
        #expect(coordinator.selectedSubject?.url == zip.standardizedFileURL)
        #expect(coordinator.actionVM.filteredActions.contains { $0.name == "Share…" })
    }

    @Test func aCompressThatFailsSaysSo() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        choose(fixture.note, in: coordinator)
        try selectAction("Compress", in: coordinator)
        let generation = try generation(of: coordinator.submit())

        coordinator.receiveFileOperation(.failure(.failed), generation: generation)

        #expect(coordinator.fileOperationFailure == "Couldn't compress")
        #expect(coordinator.selectedSubject?.url == fixture.note)
    }
}
