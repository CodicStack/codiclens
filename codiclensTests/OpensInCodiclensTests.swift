import AppKit
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// A file whose default app is Codiclens itself — a type nothing else
/// installed claims, made Codiclens's by Open With's rank `Alternate` — is
/// shown in Quick Look where it would have been opened, and the Panel stays.
/// Opening it would only send it back in as an Incoming Subject.
///
/// The recording runner says who opens what, so LaunchServices is never asked.
@MainActor
struct OpensInCodiclensTests {

    private struct Fixture {
        let root: URL
        let coordinator: CommandCoordinator
        let runner: RecordingEffectRunner

        var document: URL { root.appendingPathComponent("plan.pages").standardizedFileURL }
        var note: URL { root.appendingPathComponent("note.txt").standardizedFileURL }
        var folder: URL { root.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL }
    }

    /// `plan.pages`, which Codiclens opens, and `note.txt` and an `Inbox`
    /// folder, which something else does unless `codiclensOpensAll`.
    private func makeFixture(codiclensOpensAll: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-opens-itself-\(UUID().uuidString)")
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Inbox", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("pages".utf8).write(to: root.appendingPathComponent("plan.pages"))
        try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let runner = RecordingEffectRunner()
        runner.codiclensOpens = { url in codiclensOpensAll || url.pathExtension == "pages" }
        return Fixture(root: root, coordinator: CommandCoordinator.isolated(runner: runner), runner: runner)
    }

    private func quickLook(_ url: URL) -> Effect {
        .quickLook(QuickLookContext(items: [QuickLookPreviewItem(url: url)], selectedIndex: 0))
    }

    private func selectAction(_ name: String, in coordinator: CommandCoordinator) throws {
        coordinator.actionVM.selectedIndex = try #require(
            coordinator.actionVM.filteredActions.firstIndex { $0.name == name },
            "no Action named \(name)"
        )
    }

    // MARK: - Enter

    @Test func enterOnAFileCodiclensOpensIsQuickLookAndThePanelStays() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.coordinator.subjectVM.searchText = fixture.document.path

        #expect(fixture.coordinator.submit() == [quickLook(fixture.document)], "no .hide, no .open")
        #expect(fixture.runner.recorded == [quickLook(fixture.document)])
    }

    @Test func enterOnAFileAnotherAppOpensOpensIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.coordinator.subjectVM.searchText = fixture.note.path

        #expect(fixture.coordinator.submit() == [.hide, .open(fixture.note)])
    }

    @Test func enterOnAnIncomingFileCodiclensOpensIsQuickLook() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.coordinator.reset()
        fixture.coordinator.receiveIncoming(urls: [fixture.document])

        #expect(fixture.coordinator.submit() == [quickLook(fixture.document)])
        #expect(fixture.coordinator.standingSubject?.url == fixture.document, "it still stands")
    }

    @Test func enterOnTheLastSubjectCodiclensOpensIsQuickLook() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.coordinator.subjectVM.searchText = fixture.document.path
        fixture.coordinator.submit()
        fixture.coordinator.reset()

        #expect(fixture.coordinator.standingSubject?.url == fixture.document)
        #expect(fixture.coordinator.submit() == [quickLook(fixture.document)])
    }

    @Test func aFolderCodiclensWouldOpenIsQuickLookToo() throws {
        let fixture = try makeFixture(codiclensOpensAll: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.coordinator.subjectVM.searchText = fixture.folder.path

        #expect(fixture.coordinator.submit() == [quickLook(fixture.folder)])
    }

    @Test func anAppStillOpens() throws {
        let fixture = try makeFixture(codiclensOpensAll: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        fixture.coordinator.subjectVM.results = [Subject(
            displayName: "Calculator", path: calculator.path, url: calculator, icon: NSImage(),
            kind: .app(bundleIdentifier: "com.apple.calculator", isRunning: false)
        )]
        fixture.coordinator.subjectVM.selectedIndex = 0

        #expect(fixture.coordinator.submit() == [.hide, .open(calculator)])
    }

    /// The Panel's own preview, already open on the file, stays open: Enter
    /// shows the file, it never closes what shows it.
    @Test func thePanelsOwnPreviewStaysOpen() throws {
        let fixture = try makeFixture(codiclensOpensAll: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.subjectVM.results = [Subject(
            displayName: "note.txt", path: fixture.note.path, url: fixture.note, icon: NSImage(),
            kind: .file(contentType: .plainText),
            passage: SubjectPassage(excerpt: "hello", matches: [0..<5])
        )]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.triggerQuickLook()
        #expect(coordinator.passagePreview != nil)

        #expect(coordinator.submit().isEmpty)
        #expect(coordinator.passagePreview != nil)
    }

    // MARK: - Actions

    @Test func theOpenActionIsQuickLook() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = fixture.document.path
        coordinator.advancePhase()
        try selectAction("Open", in: coordinator)

        #expect(coordinator.submit() == [quickLook(fixture.document)])
        #expect(coordinator.phase == .pickingAction, "the Panel stays on the Actions")
    }

    @Test func finderOpeningAFileTargetCodiclensOpensIsQuickLook() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        coordinator.subjectVM.results = [Subject(
            displayName: "Finder", path: finder.path, url: finder, icon: NSImage(),
            kind: .app(bundleIdentifier: "com.apple.finder", isRunning: true)
        )]
        coordinator.subjectVM.selectedIndex = 0
        coordinator.advancePhase()
        try selectAction("Open File", in: coordinator)
        _ = coordinator.submit()
        #expect(coordinator.phase == .pickingTarget)
        coordinator.targetVM.filteredTargets = [ActionTarget(
            name: "plan.pages", icon: NSImage(), url: fixture.document, sharingService: nil
        )]
        coordinator.targetVM.selectedIndex = 0

        #expect(coordinator.submit() == [quickLook(fixture.document)])
    }

    // MARK: - QuickTime saying no

    @Test func quickTimeSayingNoOnAFileCodiclensOpensIsQuickLook() throws {
        let runner = RecordingEffectRunner()
        runner.codiclensOpens = { _ in true }
        let coordinator = CommandCoordinator.isolated(runner: runner)
        let url = URL(fileURLWithPath: "/tmp/talk.mp4")
        coordinator.subjectVM.results = [Subject(
            displayName: "talk.mp4", path: url.path, url: url, icon: NSImage(),
            kind: .file(contentType: .mpeg4Movie), thumbnailURL: url,
            passage: SubjectPassage(excerpt: "…the invoice number…", matches: [5..<12], seconds: 842)
        )]
        coordinator.subjectVM.selectedIndex = 0
        guard case .openAtMoment(_, _, let generation)? = coordinator.submit().first else {
            Issue.record("expected QuickTime")
            return
        }
        runner.clear()

        coordinator.receiveMomentOpen(succeeded: false, generation: generation)

        #expect(runner.recorded == [quickLook(url)])
        #expect(coordinator.momentOpenNote == nil, "nothing was opened from the start")
    }

    // MARK: - The runner

    @Test func theRunnerComparesTheDefaultAppsBundleIdentifierWithItsOwn() throws {
        let own = try #require(Bundle.main.bundleIdentifier)
        let file = URL(fileURLWithPath: "/tmp/plan.pages")
        let pasteboard = NSPasteboard(name: .init("codiclens-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        #expect(SystemEffectRunner(pasteboard: pasteboard, defaultApplication: { _ in own })
            .opensInCodiclens(file))
        #expect(!SystemEffectRunner(pasteboard: pasteboard, defaultApplication: { _ in "com.apple.TextEdit" })
            .opensInCodiclens(file))
        #expect(!SystemEffectRunner(pasteboard: pasteboard, defaultApplication: { _ in nil })
            .opensInCodiclens(file), "no app at all")
        #expect(!SystemEffectRunner(pasteboard: pasteboard, defaultApplication: { _ in own })
            .opensInCodiclens(URL(string: "https://codictate.app")!), "only files and folders")
    }
}
