import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// A File Result that matched inside its file: its Passage travels from the
/// row to the Subject and the Card and on into the Action Phase; Shift+Space
/// opens the Panel's own preview at it instead of Quick Look; Enter on a
/// recording that matched at a moment asks QuickTime to play it from there.
///
/// The File Index is a stand-in and the files are real, in a temp folder:
/// choosing a File Result resolves its file on disk (`PathSubject`).
@MainActor
struct PassageCommandTests {

    private struct Fixture {
        let coordinator: CommandCoordinator
        let runner: RecordingEffectRunner
        let schedule: HeldSearchSchedule
        let root: URL

        func url(_ name: String) -> URL { root.appendingPathComponent(name).standardizedFileURL }
    }

    /// `files` are written to a temp folder (removed by the caller) and the
    /// File Index answers every Query with them, in order, each with its
    /// Passage where it has one.
    private func makeFixture(_ files: [(name: String, passage: FileHit.Passage?)]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-passage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var hits: [FileHit] = []
        for (offset, file) in files.enumerated() {
            let url = root.appendingPathComponent(file.name)
            try Data("the invoice number".utf8).write(to: url)
            var hit = FileHit(url: url, name: file.name, folder: root.path, kind: .file,
                              score: file.passage == nil ? offset : FileHit.contentScore + offset)
            hit.passage = file.passage
            hits.append(hit)
        }
        let runner = RecordingEffectRunner()
        let schedule = HeldSearchSchedule()
        let sources = SourceStore(defaults: ThrowawayDefaults())
        for kind in [Source.Kind.emoji, .clipboardHistory, .builtIns] {
            sources.setEnabled(false, for: Source(kind: kind, isEnabled: true).id)
        }
        let coordinator = CommandCoordinator.isolated(
            runner: runner, sources: sources, searchFiles: { _ in hits }, searchSchedule: schedule
        )
        return Fixture(coordinator: coordinator, runner: runner, schedule: schedule, root: root)
    }

    /// What FTS5's `snippet()` hands the File Index for "invoice".
    private let invoicePassage = FileIndexReader.passage(snippet: "…the \u{1}invoice\u{2} number…", page: nil)

    private func search(_ fixture: Fixture, _ query: String = "invoice") async {
        fixture.coordinator.subjectVM.searchText = query
        await fixture.schedule.runSearches()
    }

    /// A Subject stood straight in Subject search's Results, the way the
    /// Card tests do: for a Passage the File Index cannot make yet, one with
    /// a moment.
    private func stand(_ subject: Subject, in coordinator: CommandCoordinator) {
        coordinator.subjectVM.results = [subject]
        coordinator.subjectVM.selectedIndex = 0
    }

    private func video(at url: URL, seconds: Double?) -> Subject {
        Subject(
            displayName: url.lastPathComponent, path: url.path, url: url, icon: NSImage(),
            kind: .file(contentType: .mpeg4Movie), thumbnailURL: url,
            passage: SubjectPassage(excerpt: "…the invoice number…", matches: [5..<12], seconds: seconds)
        )
    }

    private func selectAction(_ name: String, in coordinator: CommandCoordinator) throws {
        let index = try #require(coordinator.actionVM.filteredActions.firstIndex { $0.name == name })
        coordinator.actionVM.selectedIndex = index
    }

    // MARK: - The Passage travels

    @Test func thePassageTravelsFromTheRowToTheSubjectAndIntoTheActionPhase() async throws {
        let fixture = try makeFixture([("notes.txt", invoicePassage)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        await search(fixture)

        let expected = SubjectPassage(excerpt: "…the invoice number…", matches: [5..<12])
        let row = try #require(coordinator.subjectVM.results.first)
        #expect(row.passage == expected, "the row's Subject carries it")
        #expect(CardPassage(row)?.line == expected.markedExcerpt, "the Card shows it, underlined")

        coordinator.advancePhase()
        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.selectedSubject?.url == fixture.url("notes.txt"), "resolved again on disk")
        #expect(coordinator.selectedSubject?.passage == expected, "and still carrying it after Tab")

        coordinator.retreatPhase()
        coordinator.advancePhase()
        #expect(coordinator.selectedSubject?.passage == expected)
    }

    @Test func aFileThatMatchedOnItsNameHasNoPassage() async throws {
        let fixture = try makeFixture([("invoice.txt", nil)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await search(fixture)

        #expect(fixture.coordinator.subjectVM.results.first?.passage == nil)
        #expect(fixture.coordinator.subjectVM.results.first.flatMap(CardPassage.init) == nil)
    }

    @Test func theMarkedWordsAreUnderlinedOnTheCard() throws {
        let passage = SubjectPassage(excerpt: "…the invoice number…", matches: [5..<12])
        let underlined = passage.markedExcerpt.runs.filter { $0.underlineStyle != nil }
        #expect(underlined.map { String(passage.markedExcerpt[$0.range].characters) } == ["invoice"])

        let byMeaning = SubjectPassage(excerpt: "…the bill for March…")
        #expect(byMeaning.markedExcerpt.runs.allSatisfy { $0.underlineStyle == nil }, "nothing to mark")
    }

    @Test func theCardShowsAPageForAPDFAndAMomentForAVideo() {
        let pdf = URL(fileURLWithPath: "/tmp/report.pdf")
        let pdfSubject = Subject(
            displayName: "report.pdf", path: pdf.path, url: pdf, icon: NSImage(), kind: .file(contentType: .pdf),
            passage: SubjectPassage(excerpt: "…invoice…", matches: [1..<8], page: 4)
        )
        #expect(CardPassage(pdfSubject) == CardPassage(pdfSubject))
        #expect(CardPassage(pdfSubject)?.moment == .page(4))
        #expect(CardPassage(pdfSubject).map { String($0.line.characters) } == "page 4")

        let movie = video(at: URL(fileURLWithPath: "/tmp/talk.mp4"), seconds: 842)
        #expect(CardPassage(movie)?.moment == .second(842))
        #expect(CardPassage(movie).map { String($0.line.characters) } == "at 14:02")

        let photo = URL(fileURLWithPath: "/tmp/Screenshot.png")
        let screenshot = Subject(
            displayName: "Screenshot.png", path: photo.path, url: photo, icon: NSImage(),
            kind: .file(contentType: .png), passage: SubjectPassage(excerpt: "invoice", matches: [0..<7])
        )
        #expect(CardPassage(screenshot) == nil, "an image is its picture, as ever")
    }

    @Test func aMomentReadsAsAPlayerShowsIt() {
        #expect(SubjectPassage.clock(842) == "14:02")
        #expect(SubjectPassage.clock(62.9) == "1:02")
        #expect(SubjectPassage.clock(3725) == "1:02:05")
    }

    // MARK: - Shift+Space

    @Test func shiftSpaceOnAContentHitOpensTheOwnPreviewNotQuickLook() async throws {
        let fixture = try makeFixture([("notes.txt", invoicePassage)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await search(fixture)

        fixture.coordinator.triggerQuickLook()

        let preview = try #require(fixture.coordinator.passagePreview)
        #expect(preview.url == fixture.url("notes.txt"))
        #expect(preview.kind == .text(monospaced: false))
        #expect(preview.passage == SubjectPassage(excerpt: "…the invoice number…", matches: [5..<12]))
        #expect(fixture.runner.recorded.isEmpty, "no Quick Look, and nothing activates")
    }

    @Test func codeIsPreviewedMonospaced() async throws {
        let fixture = try makeFixture([("Invoice.swift", invoicePassage)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await search(fixture)

        fixture.coordinator.triggerQuickLook()

        #expect(fixture.coordinator.passagePreview?.kind == .text(monospaced: true))
    }

    @Test func shiftSpaceOnAPDFHitOpensItAtThePage() async throws {
        let page = FileIndexReader.passage(snippet: "…the \u{1}invoice\u{2} number…", page: 4)
        let fixture = try makeFixture([("report.pdf", page)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await search(fixture)

        fixture.coordinator.triggerQuickLook()

        #expect(fixture.coordinator.passagePreview?.kind == .pdf(page: 4))
        #expect(fixture.coordinator.passagePreview?.locationLabel == "page 4")
    }

    @Test func shiftSpaceOnATimedVideoPlaysItFromTheMoment() throws {
        let coordinator = CommandCoordinator.isolated()
        let url = URL(fileURLWithPath: "/tmp/talk.mp4")
        stand(video(at: url, seconds: 842), in: coordinator)

        coordinator.triggerQuickLook()

        #expect(coordinator.passagePreview?.kind == .media(seconds: 842, isVideo: true))
        #expect(coordinator.passagePreview?.locationLabel == "at 14:02")
    }

    @Test func shiftSpaceOnANameHitIsQuickLook() async throws {
        let fixture = try makeFixture([("invoice.txt", nil)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await search(fixture)

        fixture.coordinator.triggerQuickLook()

        #expect(fixture.coordinator.passagePreview == nil)
        guard case .quickLook(let context)? = fixture.runner.recorded.first else {
            Issue.record("expected Quick Look, got \(fixture.runner.recorded)")
            return
        }
        #expect(context.items.map(\.url) == [fixture.url("invoice.txt")])
    }

    /// A screenshot found by its OCR'd words, and a video before the File
    /// Index has moments, are Quick Look's.
    @Test func whatTheOwnPreviewCannotShowIsQuickLook() throws {
        let runner = RecordingEffectRunner()
        let coordinator = CommandCoordinator.isolated(runner: runner)
        stand(video(at: URL(fileURLWithPath: "/tmp/talk.mp4"), seconds: nil), in: coordinator)

        coordinator.triggerQuickLook()

        #expect(coordinator.passagePreview == nil)
        guard case .quickLook? = runner.recorded.first else {
            Issue.record("expected Quick Look, got \(runner.recorded)")
            return
        }
    }

    @Test func shiftSpaceInTheActionPhaseOpensTheChosenSubjectAtItsPassage() async throws {
        let fixture = try makeFixture([("notes.txt", invoicePassage)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await search(fixture)
        fixture.coordinator.advancePhase()

        fixture.coordinator.triggerQuickLook()

        #expect(fixture.coordinator.passagePreview?.url == fixture.url("notes.txt"))
        #expect(fixture.runner.recorded.isEmpty)
    }

    @Test func theQuickLookActionOpensTheOwnPreviewToo() async throws {
        let fixture = try makeFixture([("notes.txt", invoicePassage)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await search(fixture)
        fixture.coordinator.advancePhase()
        try selectAction("Quick Look", in: fixture.coordinator)

        #expect(fixture.coordinator.submit().isEmpty)
        #expect(fixture.coordinator.passagePreview?.url == fixture.url("notes.txt"))
    }

    @Test func shiftSpaceEscapeTypingAndTabCloseThePreview() async throws {
        let fixture = try makeFixture([("notes.txt", invoicePassage)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        await search(fixture)

        coordinator.triggerQuickLook()
        coordinator.triggerQuickLook()
        #expect(coordinator.passagePreview == nil, "Shift+Space again")

        coordinator.triggerQuickLook()
        #expect(coordinator.handleEscape(), "Escape is the preview's first")
        #expect(coordinator.passagePreview == nil)
        #expect(coordinator.phase == .searchingSubject)

        coordinator.triggerQuickLook()
        coordinator.acceptTypedText("invoices")
        #expect(coordinator.passagePreview == nil, "typing")

        await search(fixture)
        coordinator.triggerQuickLook()
        coordinator.advancePhase()
        #expect(coordinator.passagePreview == nil, "Tab")

        coordinator.triggerQuickLook()
        coordinator.closePassagePreview()
        #expect(coordinator.passagePreview == nil, "the Panel going")
        #expect(fixture.runner.recorded.isEmpty)
    }

    // MARK: - Enter at the moment

    @Test func enterOnATimedVideoAsksQuickTimeAndWaitsForItsAnswer() throws {
        let runner = RecordingEffectRunner()
        let coordinator = CommandCoordinator.isolated(runner: runner)
        let url = URL(fileURLWithPath: "/tmp/talk.mp4")
        stand(video(at: url, seconds: 842), in: coordinator)

        let effects = coordinator.submit()

        guard case .openAtMoment(let opened, let seconds, let generation)? = effects.first, effects.count == 1 else {
            Issue.record("expected QuickTime alone, no .hide: \(effects)")
            return
        }
        #expect(opened == url && seconds == 842)
        #expect(coordinator.momentOpenNote == "Opening at 14:02…")
        #expect(coordinator.submit().isEmpty, "a second Enter waits too")

        runner.clear()
        coordinator.receiveMomentOpen(succeeded: true, generation: generation)
        #expect(runner.recorded == [.hide])
        #expect(coordinator.momentOpenNote == nil)
    }

    @Test func quickTimeSayingNoOpensTheFileFromTheStartAndSaysSo() throws {
        let runner = RecordingEffectRunner()
        let coordinator = CommandCoordinator.isolated(runner: runner)
        let url = URL(fileURLWithPath: "/tmp/talk.mp4")
        stand(video(at: url, seconds: 842), in: coordinator)
        guard case .openAtMoment(_, _, let generation)? = coordinator.submit().first else {
            Issue.record("expected QuickTime")
            return
        }

        runner.clear()
        coordinator.receiveMomentOpen(succeeded: false, generation: generation)

        #expect(runner.recorded == [.open(url)])
        #expect(coordinator.momentOpenNote == "Opened from the start")
        #expect(!coordinator.isMomentOpenInFlight)
    }

    @Test func anAnswerForAPanelSinceResetIsDropped() throws {
        let runner = RecordingEffectRunner()
        let coordinator = CommandCoordinator.isolated(runner: runner)
        stand(video(at: URL(fileURLWithPath: "/tmp/talk.mp4"), seconds: 842), in: coordinator)
        guard case .openAtMoment(_, _, let generation)? = coordinator.submit().first else {
            Issue.record("expected QuickTime")
            return
        }
        coordinator.reset()
        runner.clear()

        coordinator.receiveMomentOpen(succeeded: false, generation: generation)

        #expect(runner.recorded.isEmpty)
        #expect(coordinator.momentOpenNote == nil)
    }

    @Test func enterOnAVideoWithNoMomentOpensItAsEver() throws {
        let coordinator = CommandCoordinator.isolated()
        let url = URL(fileURLWithPath: "/tmp/talk.mp4")
        stand(video(at: url, seconds: nil), in: coordinator)

        #expect(coordinator.submit() == [.hide, .open(url)])
    }

    @Test func enterOnAPDFAtAPageOpensItNormally() async throws {
        let page = FileIndexReader.passage(snippet: "…the \u{1}invoice\u{2} number…", page: 4)
        let fixture = try makeFixture([("report.pdf", page)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await search(fixture)

        #expect(fixture.coordinator.submit() == [.hide, .open(fixture.url("report.pdf"))])
    }

    /// A video the File Index found by meaning, at a frame 842 s in: the
    /// moment comes from its Passage's start to the Card's frame, the Passage
    /// Preview's start and QuickTime's.
    @Test func aVideoFoundByMeaningAtAMomentIsShownPlayedAndOpenedThere() async throws {
        let frame = FileHit.Passage(excerpt: "", matches: [], page: nil, start: 842, end: 845, modality: .image)
        let fixture = try makeFixture([("talk.mp4", frame)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "conference talk"
        await fixture.schedule.typingPaused()

        let row = try #require(coordinator.subjectVM.results.first)
        #expect(row.passage?.seconds == 842)
        #expect(CardPassage(row)?.moment == .second(842))
        #expect(CardPassage(row).map { String($0.line.characters) } == "at 14:02")

        coordinator.triggerQuickLook()
        #expect(coordinator.passagePreview?.kind == .media(seconds: 842, isVideo: true))
        #expect(coordinator.passagePreview?.locationLabel == "at 14:02")
        #expect(fixture.runner.recorded.isEmpty, "not Quick Look")
        coordinator.closePassagePreview()

        let effects = coordinator.submit()
        guard case .openAtMoment(let url, let seconds, _)? = effects.first, effects.count == 1 else {
            Issue.record("expected QuickTime, got \(effects)")
            return
        }
        #expect(url == fixture.url("talk.mp4") && seconds == 842)
    }

    @Test func openOnATimedVideosActionsIsQuickTimeToo() throws {
        let coordinator = CommandCoordinator.isolated()
        let url = URL(fileURLWithPath: "/tmp/talk.mp4")
        stand(video(at: url, seconds: 842), in: coordinator)
        coordinator.advancePhase()
        try selectAction("Open", in: coordinator)

        let effects = coordinator.submit()

        guard case .openAtMoment(url, 842, _)? = effects.first else {
            Issue.record("expected QuickTime, got \(effects)")
            return
        }
    }
}

