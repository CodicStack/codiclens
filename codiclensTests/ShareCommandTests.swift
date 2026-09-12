import AppKit
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// Share on every Subject that has content, and what each one actually hands
/// to the service. See `CONTEXT.md`, **Share**.
///
/// Nothing here performs a Share or asserts on the list of services the system
/// offers: the Target is a service built for the test, which does nothing
/// unless it is performed.
@MainActor
struct ShareCommandTests {

    // MARK: - Fixtures

    private func makeCoordinator() -> (CommandCoordinator, RecordingEffectRunner, ClipboardHistory) {
        let runner = RecordingEffectRunner()
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        let coordinator = CommandCoordinator(runner: runner, history: history, index: inertAppIndex)
        return (coordinator, runner, history)
    }

    /// A sharing service of the test's own, so no system service is ever asked
    /// to do anything.
    private func testService() -> NSSharingService {
        NSSharingService(title: "Test Recipient", image: NSImage(), alternateImage: nil) {}
    }

    private func selectAction(_ name: String, in coordinator: CommandCoordinator) throws {
        let index = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == name },
            "no action named \(name)"
        )
        coordinator.actionVM.selectedIndex = index
    }

    /// Drives Subject → Share → a chosen Target, and answers with the effects
    /// the final Enter produces.
    private func share(
        from coordinator: CommandCoordinator,
        via service: NSSharingService
    ) throws -> [Effect] {
        coordinator.advancePhase()
        try selectAction("Share…", in: coordinator)
        coordinator.advancePhase()
        #expect(coordinator.phase == .pickingTarget)

        coordinator.targetVM.filteredTargets = [
            ActionTarget(name: "Test Recipient", icon: NSImage(), url: nil, sharingService: service)
        ]
        coordinator.targetVM.selectedIndex = 0
        return coordinator.submit()
    }

    /// A directory holding one `note.txt`. Removed by the caller.
    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(
            to: root.appendingPathComponent("note.txt"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    private func names(for subject: Subject) -> [String] {
        SubjectAction.actions(for: subject).map(\.name)
    }

    private func emojiSubject() -> Subject {
        Subject(emoji: Emoji(string: "🔥", name: "fire", keywords: ["hot"], groupIndex: 0))
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

    // MARK: - Which Subjects have Share

    @Test func anImageClipboardEntryOffersShare() {
        let (coordinator, _, history) = makeCoordinator()
        history.recordImage(Data([0x89, 0x50]))
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
        coordinator.advancePhase()

        #expect(coordinator.actionVM.filteredActions.map(\.name).contains("Share…"))
    }

    @Test func aFileSubjectOffersShare() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let subject = try #require(PathSubject.subject(for: root.appendingPathComponent("note.txt")))
        #expect(names(for: subject).contains("Share…"))
    }

    @Test func aFolderSubjectOffersShare() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let subject = try #require(PathSubject.subject(for: root))
        guard case .folder = subject.kind else {
            Issue.record("expected a folder Subject")
            return
        }
        #expect(names(for: subject).contains("Share…"))
    }

    @Test func anEmojiSubjectOffersShare() {
        #expect(names(for: emojiSubject()).contains("Share…"))
    }

    /// The grammar gives an Action one Target, and the Finder Subject's Target
    /// is the file. A file found there is shared by promoting it first.
    @Test func theFinderSubjectDoesNotOfferShare() {
        let finderNames = names(for: finderSubject())
        #expect(finderNames.contains("Share…") == false)
        #expect(finderNames.contains("Use as Subject"), "the route to Share is through the Subject")
    }

    @Test func anAppOffersNoShare() {
        let subject = Subject(
            displayName: "Safari",
            path: "/Applications/Safari.app",
            url: URL(fileURLWithPath: "/Applications/Safari.app"),
            icon: NSImage(),
            kind: .app(bundleIdentifier: "com.apple.Safari", isRunning: false)
        )

        #expect(names(for: subject).contains("Share…") == false)
    }

    // MARK: - What a Share hands over

    @Test func sharingTextHidesThenSharesTheText() throws {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.subjectVM.results = [Subject(text: "hello")]
        coordinator.subjectVM.selectedIndex = 0
        let service = testService()

        #expect(try share(from: coordinator, via: service) == [.hide, .share(.text("hello"), via: service)])
    }

    @Test func sharingAnEmojiSharesItsText() throws {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.subjectVM.results = [emojiSubject()]
        coordinator.subjectVM.selectedIndex = 0
        let service = testService()

        #expect(try share(from: coordinator, via: service) == [.hide, .share(.text("🔥"), via: service)])
    }

    /// The stored PNG, not its bytes: a file keeps its name on the way across,
    /// which is what AirDrop shows on the other machine.
    @Test func sharingAClipboardImageSharesTheStoredPNG() throws {
        let (coordinator, _, history) = makeCoordinator()
        history.recordImage(Data([0x89, 0x50, 0x4E, 0x47]))
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
        let service = testService()
        let item = try #require(history.items.first)
        let stored = try #require(history.imageURL(for: item))

        #expect(try share(from: coordinator, via: service) == [.hide, .share(.fileURL(stored), via: service)])
    }

    /// Share's Payload is a second question from Paste's. A file URL on the
    /// pasteboard pastes a file reference; a Clipboard Image must still paste
    /// pixels.
    @Test func pastingAClipboardImageStillPastesImageBytes() throws {
        let (coordinator, _, history) = makeCoordinator()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        history.recordImage(png)
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
        coordinator.advancePhase()
        try selectAction("Paste", in: coordinator)

        #expect(coordinator.submit() == [.paste(.image(png))])
    }

    @Test func copyingAClipboardImageStillWritesImageBytes() throws {
        let (coordinator, _, history) = makeCoordinator()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        history.recordImage(png)
        coordinator.phase = .browsingClipboard
        coordinator.clipboardVM.load()
        coordinator.advancePhase()
        try selectAction("Copy", in: coordinator)

        #expect(coordinator.submit() == [.hide, .copy(.image(png))])
    }

    @Test func sharingAFileSharesItsURL() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.txt")

        let (coordinator, _, _) = makeCoordinator()
        coordinator.subjectVM.searchText = note.path
        let service = testService()

        let effects = try share(from: coordinator, via: service)
        guard case .share(let payload, _) = try #require(effects.last) else {
            Issue.record("expected a share effect")
            return
        }
        #expect(payload == .fileURL(note))
    }

    // MARK: - Text as a share item

    private func url(of item: Any) -> URL? {
        (item as? NSURL) as URL?
    }

    @Test func textThatIsAURLSharesAsALink() throws {
        let item = SharePayloadItems.textItem(for: "https://example.com/a?b=c")

        let link = try #require(url(of: item), "a URL shares as an NSURL, so AirDrop will take it")
        #expect(link.isFileURL == false)
        #expect(link.absoluteString == "https://example.com/a?b=c")
    }

    @Test(arguments: [
        "not a url at all",
        "look at https://example.com",
        "mailto:someone@example.com",
        "ftp://example.com/file",
    ])
    func textThatIsNotAnHTTPURLIsNotALink(text: String) {
        #expect(SharePayloadItems.linkURL(for: text) == nil)
    }

    /// AirDrop refuses a string, so prose goes across as a file (verified
    /// 2026-09-11).
    @Test func plainTextSharesAsATextFileNamedAfterItsFirstLine() throws {
        let item = SharePayloadItems.textItem(for: "Shopping list")
        let file = try #require(url(of: item))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        #expect(file.isFileURL)
        #expect(file.lastPathComponent == "Shopping list.txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == "Shopping list")
    }

    @Test func twoSharesOfTheSameTextCannotCollide() throws {
        let first = try #require(url(of: SharePayloadItems.textItem(for: "note")))
        let second = try #require(url(of: SharePayloadItems.textItem(for: "note")))
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        #expect(first != second, "each Share writes into a directory of its own")
        #expect(first.lastPathComponent == second.lastPathComponent)
    }

    @Test func theFileNameComesFromTheFirstNonEmptyLine() {
        #expect(SharePayloadItems.fileName(for: "\n\n   \nSecond line\nthird") == "Second line.txt")
    }

    @Test func theFileNameCollapsesWhitespace() {
        #expect(SharePayloadItems.fileName(for: "  spaced   out\ttext  ") == "spaced out text.txt")
    }

    @Test func theFileNameDropsSeparators() {
        #expect(SharePayloadItems.fileName(for: "a/b:c") == "abc.txt")
    }

    @Test func theFileNameStopsAtFortyCharacters() {
        let long = String(repeating: "x", count: 60)
        let name = SharePayloadItems.fileName(for: long)

        #expect(name == String(repeating: "x", count: 40) + ".txt")
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func emptyTextStillGetsAName(blank: String) {
        #expect(SharePayloadItems.fileName(for: blank) == "Text.txt")
    }

    // MARK: - A Clipboard Item is a snapshot

    /// The stored PNG, never the file it was copied from — a later edit to that
    /// file changes nothing here. See `CONTEXT.md`, **Clipboard Item**.
    @Test func previewingAnImageEntryShowsTheSnapshotAndNotTheOriginal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = root.appendingPathComponent("original.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: original)

        let history = ClipboardHistory(store: FileClipboardStore(root: root.appendingPathComponent("store")))
        history.recordImage(Data([0x89, 0x50, 0x4E, 0x47]), originalURL: original)

        let item = try #require(history.items.first)
        #expect(FileManager.default.fileExists(atPath: original.path), "the original is still there")
        #expect(history.previewURL(for: item) == history.imageURL(for: item))
        #expect(history.previewURL(for: item) != original)
        #expect(item.originalFilePath == original.path, "the original still lends the name")
    }
}
