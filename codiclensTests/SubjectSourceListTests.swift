import AppKit
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// The list below the apps in Subject search: File Results, Clipboard Items
/// and Emoji, ranked against each other, staying on screen while the user
/// types and re-ranked as answers land — see
/// `docs/adr/0012-files-in-subject-search-text-mode-is-cmd-e.md`.
///
/// The File Index is a stand-in and nothing runs on a clock: the searches and
/// the pause are held by a `HeldSearchSchedule`, and each test runs them when
/// it means the keystroke's search to land (`runSearches`) or typing to pause
/// (`typingPaused`).
@MainActor
struct SubjectSourceListTests {

    /// A File Index stand-in whose answer can change between two searches and
    /// differ per Query, which records what it was asked, and which can hold a
    /// search for a Query until the test lets it go.
    final class FakeFileIndex: Sendable {
        private let state: Mutex<(hits: [FileHit], answers: [String: [FileHit]], asked: [String])>
        private let held: [String: DispatchSemaphore]
        private let askedContinuation: AsyncStream<String>.Continuation

        /// Every Query the File Index is asked, as it is asked.
        let askedQueries: AsyncStream<String>

        init(_ hits: [FileHit] = [], answers: [String: [FileHit]] = [:], holding: Set<String> = []) {
            state = Mutex((hits, answers, []))
            held = Dictionary(uniqueKeysWithValues: holding.map { ($0, DispatchSemaphore(value: 0)) })
            (askedQueries, askedContinuation) = AsyncStream.makeStream(of: String.self)
        }

        var hits: [FileHit] {
            get { state.withLock { $0.hits } }
            set { state.withLock { $0.hits = newValue } }
        }

        var answers: [String: [FileHit]] {
            get { state.withLock { $0.answers } }
            set { state.withLock { $0.answers = newValue } }
        }

        var asked: [String] { state.withLock { $0.asked } }
        var calls: Int { asked.count }

        /// Lets a held search for `query` answer.
        func letGo(_ query: String) {
            held[query]?.signal()
        }

        var search: FileIndex.Search {
            { [self] query in
                state.withLock { $0.asked.append(query) }
                askedContinuation.yield(query)
                held[query]?.wait()
                return state.withLock { $0.answers[query] ?? $0.hits }
            }
        }
    }

    /// The File Index's settled search, standing in: answers per Query,
    /// records what it was asked, and while holding keeps each call waiting
    /// until the test lets it go, with its answer or with the nothing the
    /// File Index gives a call superseded or cancelled.
    final class FakeSettledSearch: Sendable {
        private let state: Mutex<(answers: [String: [FileHit]], asked: [String], waiting: [CheckedContinuation<Bool, Never>])>
        private let isHolding: Bool
        private let askedContinuation: AsyncStream<String>.Continuation

        /// Every Query it is asked, once the call is waiting where holding.
        let askedQueries: AsyncStream<String>

        init(answers: [String: [FileHit]], holding: Bool = false) {
            state = Mutex((answers, [], []))
            isHolding = holding
            (askedQueries, askedContinuation) = AsyncStream.makeStream(of: String.self)
        }

        var asked: [String] { state.withLock { $0.asked } }

        /// Lets the oldest waiting call answer: its Query's answer, or,
        /// `superseded`, nothing.
        func letGo(superseded: Bool = false) {
            let call = state.withLock { $0.waiting.isEmpty ? nil : $0.waiting.removeFirst() }
            call?.resume(returning: superseded)
        }

        var search: FileIndex.SettledSearch {
            { [self] query in
                state.withLock { $0.asked.append(query) }
                if isHolding {
                    let superseded = await withCheckedContinuation { call in
                        state.withLock { $0.waiting.append(call) }
                        askedContinuation.yield(query)
                    }
                    if superseded { return [] }
                } else {
                    askedContinuation.yield(query)
                }
                return state.withLock { $0.answers[query] ?? [] }
            }
        }
    }

    private struct Fixture {
        let coordinator: CommandCoordinator
        let history: ClipboardHistory
        let files: FakeFileIndex
        let sources: SourceStore
        let recents: EmojiRecents
        let schedule: HeldSearchSchedule
    }

    private func makeFixture(
        files: [FileHit] = [],
        fileIndex: FakeFileIndex? = nil,
        settled: FakeSettledSearch? = nil,
        clipboard: [String] = [],
        index: AppIndex? = nil,
        disabling disabled: [Source.Kind] = []
    ) throws -> Fixture {
        let history = ClipboardHistory(store: InMemoryClipboardStore())
        // Recorded oldest first, so the first one listed is the newest.
        for text in clipboard.reversed() { history.recordText(text) }
        let recents = EmojiRecents(store: InMemoryEmojiRecentsStore())
        let emojiVM = EmojiSearchVM(
            index: try EmojiIndex.bundled(),
            recents: recents,
            preferences: EmojiPreferences(defaults: ThrowawayDefaults())
        )
        let sources = SourceStore(defaults: ThrowawayDefaults())
        for kind in disabled {
            sources.setEnabled(false, for: Source(kind: kind, isEnabled: true).id)
        }
        let fileIndex = fileIndex ?? FakeFileIndex(files)
        let schedule = HeldSearchSchedule()
        let coordinator = CommandCoordinator.isolated(
            runner: RecordingEffectRunner(),
            history: history,
            emojiVM: emojiVM,
            index: index ?? inertAppIndex,
            sources: sources,
            searchFiles: fileIndex.search,
            searchSettled: settled?.search,
            searchSchedule: schedule
        )
        return Fixture(
            coordinator: coordinator,
            history: history,
            files: fileIndex,
            sources: sources,
            recents: recents,
            schedule: schedule
        )
    }

    private func hit(_ path: String, score: Int, kind: FileIndexRow.Kind = .file) -> FileHit {
        let url = URL(fileURLWithPath: path, isDirectory: kind != .file)
        return FileHit(
            url: url,
            name: url.lastPathComponent,
            folder: url.deletingLastPathComponent().path,
            kind: kind,
            score: score
        )
    }

    /// Files in `/docs`, each scored by its place: the order given is the
    /// order ranked.
    private func docs(_ names: String...) -> [FileHit] {
        names.enumerated().map { hit("/docs/" + $0.element, score: $0.offset) }
    }

    /// A directory holding one `clip notes.txt`, so `PathSubject` can resolve
    /// a File Result chosen from the list. Removed by the caller.
    private func fixtureFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-sources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("clip notes.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// An Index that has scanned one app, so a Query can be *answered*.
    private func populatedIndex() async throws -> (AppIndex, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Fixture.app"),
            withIntermediateDirectories: true
        )
        let index = AppIndex(directories: [root.path])
        index.refresh()
        await withCheckedContinuation { continuation in
            index.onFirstPopulation { continuation.resume() }
        }
        return (index, root)
    }

    private func names(_ coordinator: CommandCoordinator) -> [String] {
        coordinator.subjectVM.results.map(\.displayName)
    }

    private func selectedName(_ coordinator: CommandCoordinator) -> String? {
        let vm = coordinator.subjectVM
        return vm.results.indices.contains(vm.selectedIndex) ? vm.results[vm.selectedIndex].displayName : nil
    }

    // MARK: - While typing

    /// The apps answer on the keystroke and are on top; the list lands below
    /// them, re-ranks as typing pauses, and moves nothing above it.
    @Test func theAppsStayOnTopAndUnchangedWhileTheListLandsAndReRanks() async throws {
        let fixture = try makeFixture(
            files: docs("clipping.pdf"),
            disabling: [.emoji, .clipboardHistory]
        )
        let vm = fixture.coordinator.subjectVM

        vm.searchText = "clip"
        let appsBefore = vm.results.map(\.id)
        let rowsBefore = fixture.coordinator.currentResults.map(\.id)
        #expect(names(fixture.coordinator) == ["Clipboard"], "the Built-in, on the keystroke")

        await fixture.schedule.runSearches()
        #expect(names(fixture.coordinator) == ["Clipboard", "clipping.pdf"])

        fixture.files.hits = docs("clip art.png", "clipping.pdf")
        await fixture.schedule.typingPaused()
        #expect(names(fixture.coordinator) == ["Clipboard", "clip art.png", "clipping.pdf"])

        #expect(Array(vm.results.prefix(appsBefore.count).map(\.id)) == appsBefore)
        #expect(Array(fixture.coordinator.currentResults.prefix(rowsBefore.count).map(\.id)) == rowsBefore)
        #expect(vm.selectedIndex == 0, "the selection did not move")
    }

    /// Word matches answer every keystroke, without waiting for a pause.
    @Test func wordMatchesUpdateOnEveryKeystroke() async throws {
        let fixture = try makeFixture(
            fileIndex: FakeFileIndex(answers: ["cl": docs("clay.txt"), "cli": docs("client.txt")]),
            disabling: [.emoji, .clipboardHistory, .builtIns]
        )
        let vm = fixture.coordinator.subjectVM

        vm.searchText = "cl"
        await fixture.schedule.runSearches()
        #expect(names(fixture.coordinator) == ["clay.txt"])

        vm.searchText = "cli"
        await fixture.schedule.runSearches()
        #expect(names(fixture.coordinator) == ["client.txt"])
        #expect(fixture.files.asked == ["cl", "cli"], "no pause was waited out")
    }

    /// The list is never blanked between keystrokes: the previous answer
    /// stays, rows and ids, until the new Query's lands in its place.
    @Test func theListStaysOnScreenWhileTheNextQueryIsOut() async throws {
        let fixture = try makeFixture(
            fileIndex: FakeFileIndex(answers: ["cl": docs("clay.txt", "clip.txt"), "cli": docs("clip.txt")]),
            disabling: [.emoji, .clipboardHistory, .builtIns]
        )
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "cl"
        await fixture.schedule.runSearches()
        let shown = coordinator.currentResults.map(\.id)

        coordinator.subjectVM.searchText = "cli"
        #expect(coordinator.currentResults.map(\.id) == shown, "the same rows, not a blank list")

        await fixture.schedule.runSearches()
        #expect(coordinator.currentResults.map(\.id) == ["file:/docs/clip.txt"], "the row kept its id")
    }

    /// One search is out at a time. An answer for a Query the user has typed
    /// past is dropped, and the Queries typed while it was out come down to
    /// the newest.
    @Test func anAnswerForAQueryTypedPastNeverOverwritesTheNewerOne() async throws {
        let files = FakeFileIndex(
            answers: ["c": docs("cars.txt"), "cl": docs("clay.txt"), "clip": docs("clipping.pdf")],
            holding: ["cl", "clip"]
        )
        let fixture = try makeFixture(fileIndex: files, disabling: [.emoji, .clipboardHistory, .builtIns])
        let coordinator = fixture.coordinator
        var asked = files.askedQueries.makeAsyncIterator()

        coordinator.subjectVM.searchText = "c"
        await fixture.schedule.runSearches()
        #expect(await asked.next() == "c")
        #expect(names(coordinator) == ["cars.txt"])

        coordinator.subjectVM.searchText = "cl"
        let searching = Task { await fixture.schedule.runSearches() }
        #expect(await asked.next() == "cl")
        coordinator.subjectVM.searchText = "cli"
        coordinator.subjectVM.searchText = "clip"

        files.letGo("cl")
        #expect(await asked.next() == "clip", "the newest Query, and not the one typed between")
        #expect(names(coordinator) == ["cars.txt"], "the answer for cl did not land over clip")
        #expect(!coordinator.subjectVM.hasAnswered)

        files.letGo("clip")
        await searching.value
        #expect(names(coordinator) == ["clipping.pdf"])
        #expect(files.asked == ["c", "cl", "clip"])
    }

    /// Typing pauses once per Query: the settled pass runs once, and after
    /// it the list does not change until the Query does.
    @Test func theSettledPassRunsOnceAfterThePause() async throws {
        let fixture = try makeFixture(
            files: docs("clipping.pdf"),
            disabling: [.emoji, .clipboardHistory, .builtIns]
        )
        let vm = fixture.coordinator.subjectVM

        vm.searchText = "cl"
        vm.searchText = "cli"
        vm.searchText = "clip"
        #expect(fixture.schedule.isPauseWaiting)
        await fixture.schedule.typingPaused()

        #expect(fixture.files.asked == ["clip", "clip"], "the keystroke's search, then the settled pass")
        #expect(!fixture.schedule.isPauseWaiting)
        let settled = fixture.coordinator.currentResults.map(\.id)

        fixture.files.hits = docs("clip two.txt", "clipping.pdf")
        await fixture.schedule.typingPaused()
        #expect(fixture.files.calls == 2)
        #expect(fixture.coordinator.currentResults.map(\.id) == settled)
    }

    // MARK: - The settled pass

    /// A video found by meaning at a frame 842 s in: a File Result the word
    /// search does not have.
    private func talk() -> FileHit {
        var talk = hit("/docs/talk.mp4", score: FileHit.contentScore)
        talk.passage = FileHit.Passage(excerpt: "", matches: [], page: nil, start: 842, end: 845, modality: .image)
        talk.meaning = .image
        return talk
    }

    private func key(_ hit: SourceSearch.Hit) -> String {
        switch hit {
        case .file(let file): "file " + file.url.path
        case .clipboard(let item): "clipboard " + item.content
        case .emoji(let emoji): "emoji " + emoji.string
        }
    }

    /// The pause asks the settled search, where meaning joins, once for the
    /// Query, and its files are ranked with the Clipboard Items and Emoji as
    /// the keystroke's are. Nothing is asked again until the Query changes.
    @Test func theSettledPassAsksTheSettledSearchOnceAndRanksItWithClipboardAndEmoji() async throws {
        let settled = FakeSettledSearch(answers: ["clip": [hit("/docs/clipping.pdf", score: 0), talk()]])
        let fixture = try makeFixture(
            files: docs("clipping.pdf"), settled: settled, clipboard: ["clip this"], disabling: [.builtIns]
        )
        let vm = fixture.coordinator.subjectVM

        vm.searchText = "cli"
        vm.searchText = "clip"
        await fixture.schedule.runSearches()
        #expect(!names(fixture.coordinator).contains("talk.mp4"), "the keystroke has words alone")
        #expect(settled.asked.isEmpty)

        await fixture.schedule.typingPaused()
        #expect(settled.asked == ["clip"])
        #expect(fixture.files.asked == ["clip"], "the word search is not asked again")
        let rows = vm.sourceResults
        #expect(rows.compactMap { if case .file(let file) = $0.hit { file.name } else { nil } } == ["clipping.pdf", "talk.mp4"])
        #expect(rows.contains { $0.subject.clipboardItem?.content == "clip this" })
        #expect(rows.contains { $0.subject.emoji != nil })
        #expect(vm.results.first { $0.displayName == "talk.mp4" }?.passage?.seconds == 842)

        let expected = SourceSearch(
            query: "clip", searchFiles: { _ in [] },
            clipboard: fixture.history.items, emoji: try EmojiIndex.bundled().all, recentEmoji: []
        ).rank(files: [hit("/docs/clipping.pdf", score: 0), talk()])
        #expect(rows.map { key($0.hit) } == expected.map { key($0.hit) }, "one ranking across Sources, as the keystroke's")

        let settledRows = fixture.coordinator.currentResults.map(\.id)
        await fixture.schedule.typingPaused()
        #expect(settled.asked == ["clip"])
        #expect(fixture.coordinator.currentResults.map(\.id) == settledRows)
    }

    /// Once the settled pass has answered, a word answer for the same Query
    /// still out lands on nothing: the list does not change until the Query
    /// does.
    @Test func aWordAnswerLandingAfterTheSettledPassChangesNothing() async throws {
        let files = FakeFileIndex(answers: ["clip": docs("clipping.pdf")], holding: ["clip"])
        let settled = FakeSettledSearch(answers: ["clip": [hit("/docs/clip art.png", score: 0), talk()]])
        let fixture = try makeFixture(fileIndex: files, settled: settled, disabling: [.emoji, .clipboardHistory, .builtIns])
        var asked = files.askedQueries.makeAsyncIterator()

        fixture.coordinator.subjectVM.searchText = "clip"
        let words = Task { await fixture.schedule.runSearches() }
        #expect(await asked.next() == "clip")
        await fixture.schedule.typingPaused()
        #expect(names(fixture.coordinator) == ["clip art.png", "talk.mp4"], "the settled pass did not wait")

        files.letGo("clip")
        await words.value
        #expect(names(fixture.coordinator) == ["clip art.png", "talk.mp4"])
    }

    /// The File Index answers a settled search that a newer one superseded,
    /// or that was cancelled, with nothing. That is not an answer: only the
    /// newest settled pass lands, even for the same Query typed again.
    @Test func aSupersededSettledPassNeverOverwritesTheList() async throws {
        let settled = FakeSettledSearch(answers: ["clip": [hit("/docs/clipping.pdf", score: 0), talk()]], holding: true)
        let fixture = try makeFixture(
            files: docs("clipping.pdf"), settled: settled, disabling: [.emoji, .clipboardHistory, .builtIns]
        )
        let vm = fixture.coordinator.subjectVM
        var asked = settled.askedQueries.makeAsyncIterator()

        vm.searchText = "clip"
        await fixture.schedule.runSearches()
        let first = Task { await fixture.schedule.typingPaused() }
        #expect(await asked.next() == "clip")

        // Typed on and back while it waits, and paused again.
        vm.searchText = "clipp"
        vm.searchText = "clip"
        let second = Task { await fixture.schedule.typingPaused() }
        #expect(await asked.next() == "clip")

        settled.letGo(superseded: true)
        await first.value
        #expect(names(fixture.coordinator) == ["clipping.pdf"], "the first pass's nothing did not blank it")

        settled.letGo()
        await second.value
        #expect(names(fixture.coordinator) == ["clipping.pdf", "talk.mp4"])
    }

    // MARK: - Selection

    /// Untouched, the selection is on the first row — here the list's own,
    /// with no apps above it — whatever the list re-ranks to.
    @Test func anUntouchedSelectionStaysOnTheFirstRow() async throws {
        let fixture = try makeFixture(
            fileIndex: FakeFileIndex(answers: ["cl": docs("clay.txt", "clip.txt"), "cli": docs("clip.txt", "clay.txt")]),
            disabling: [.emoji, .clipboardHistory, .builtIns]
        )
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "cl"
        await fixture.schedule.runSearches()
        #expect(selectedName(coordinator) == "clay.txt")

        coordinator.subjectVM.searchText = "cli"
        await fixture.schedule.runSearches()
        #expect(selectedName(coordinator) == "clip.txt")
        #expect(coordinator.subjectVM.selectedIndex == 0)
    }

    /// A row the user moved onto by hand is followed by its id as the list
    /// re-ranks around it under the same Query: the settled pass moves it,
    /// and the selection goes with it.
    @Test func aHandMovedSelectionFollowsItsItemUnderTheSameQuery() async throws {
        let files = FakeFileIndex(answers: ["cl": docs("clay.txt", "clip.txt", "clipping.pdf")])
        let fixture = try makeFixture(fileIndex: files, disabling: [.emoji, .clipboardHistory])
        let coordinator = fixture.coordinator

        coordinator.subjectVM.searchText = "cl"
        await fixture.schedule.runSearches()
        #expect(names(coordinator) == ["Clipboard", "clay.txt", "clip.txt", "clipping.pdf"])
        coordinator.moveDown()
        coordinator.moveDown()
        #expect(selectedName(coordinator) == "clip.txt")

        files.answers["cl"] = docs("clip.txt", "clay.txt")
        await fixture.schedule.typingPaused()
        #expect(names(coordinator) == ["Clipboard", "clip.txt", "clay.txt"], "the apps stay on top")
        #expect(selectedName(coordinator) == "clip.txt")
        #expect(coordinator.subjectVM.selectedIndex == 1)
        #expect(coordinator.subjectVM.pinCount == 0, "nothing pinned while the Query stands")
    }

    // MARK: - Pinning

    /// Picked by hand, then the Query changes: while the new Query still
    /// matches it, the row is the first of the whole list — above the apps —
    /// and stays selected, with everything else after it in its usual order
    /// and no second copy of it. Each time it is put first, the list is told
    /// to scroll to the top.
    @Test func aPickedRowIsPinnedAboveTheAppsWhileItStillMatches() async throws {
        let files = FakeFileIndex(answers: [
            "cl": docs("clay.txt", "clip.txt"),
            "cli": docs("clipping.pdf", "client.txt", "clip.txt")
        ])
        let fixture = try makeFixture(fileIndex: files, disabling: [.emoji, .clipboardHistory])
        let coordinator = fixture.coordinator
        let vm = coordinator.subjectVM

        vm.searchText = "cl"
        await fixture.schedule.runSearches()
        coordinator.moveDown()
        coordinator.moveDown()
        #expect(selectedName(coordinator) == "clip.txt")

        vm.searchText = "cli"
        #expect(names(coordinator) == ["clip.txt", "Clipboard", "clay.txt"], "pinned while cli is out")
        #expect(vm.selectedIndex == 0)
        #expect(vm.pinCount == 1, "scroll to the top")

        await fixture.schedule.runSearches()
        #expect(names(coordinator) == ["clip.txt", "Clipboard", "clipping.pdf", "client.txt"], "once, at the top")
        #expect(selectedName(coordinator) == "clip.txt")
        #expect(vm.pinCount == 2)
        #expect(coordinator.currentResults.first?.id == "file:/docs/clip.txt")
    }

    /// A pinned row the new Query no longer matches is dropped, and the
    /// selection goes back to the first row: the top app. A word answer
    /// alone does not drop it — the settled pass can still find it — but the
    /// settled answer does, and the row coming back later is not chosen
    /// again.
    @Test func aPinnedRowTheQueryNoLongerMatchesIsDropped() async throws {
        let files = FakeFileIndex(answers: [
            "cl": docs("clay.txt", "clip.txt"),
            "clip": docs("clipping.pdf"),
            "clip ": docs("clipping.pdf", "clip.txt")
        ])
        let fixture = try makeFixture(fileIndex: files, disabling: [.emoji, .clipboardHistory])
        let coordinator = fixture.coordinator
        let vm = coordinator.subjectVM

        vm.searchText = "cl"
        await fixture.schedule.runSearches()
        coordinator.moveDown()
        coordinator.moveDown()
        #expect(selectedName(coordinator) == "clip.txt")

        vm.searchText = "clip"
        await fixture.schedule.runSearches()
        #expect(names(coordinator) == ["clip.txt", "Clipboard", "clipping.pdf"], "still pinned: the settled pass is out")

        await fixture.schedule.typingPaused()
        #expect(names(coordinator) == ["Clipboard", "clipping.pdf"])
        #expect(selectedName(coordinator) == "Clipboard", "back to the first row")
        #expect(vm.selectedIndex == 0)

        vm.searchText = "clip "
        await fixture.schedule.runSearches()
        #expect(names(coordinator) == ["clipping.pdf", "clip.txt"], "a row coming back is not pinned again")
        #expect(vm.selectedIndex == 0)
    }

    /// An app can be picked and pinned too: above the app it ranked under,
    /// and listed once.
    @Test func aPickedAppIsPinnedLikeAnyRow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-index-\(UUID().uuidString)")
        for app in ["Notes", "Keynote"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("\(app).app"),
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let index = AppIndex(directories: [root.path])
        index.refresh()
        await withCheckedContinuation { continuation in
            index.onFirstPopulation { continuation.resume() }
        }
        defer { index.stop() }
        let fixture = try makeFixture(index: index, disabling: [.emoji, .clipboardHistory, .builtIns])
        let coordinator = fixture.coordinator
        let vm = coordinator.subjectVM

        vm.searchText = "note"
        #expect(names(coordinator) == ["Notes", "Keynote"])
        coordinator.moveDown()

        vm.searchText = "not"
        #expect(names(coordinator) == ["Keynote", "Notes"])
        #expect(selectedName(coordinator) == "Keynote")
    }

    /// Moving the selection again picks again: the newly chosen row is the one
    /// pinned on the next Query, and the one pinned before takes its usual
    /// place.
    @Test func movingAgainPinsTheNewlyChosenRow() async throws {
        let files = FakeFileIndex(answers: [
            "cl": docs("clay.txt", "clip.txt"),
            "cli": docs("clipping.pdf", "client.txt", "clip.txt"),
            "clie": docs("clip.txt", "client.txt")
        ])
        let fixture = try makeFixture(fileIndex: files, disabling: [.emoji, .clipboardHistory])
        let coordinator = fixture.coordinator
        let vm = coordinator.subjectVM

        vm.searchText = "cl"
        await fixture.schedule.runSearches()
        coordinator.moveDown()
        coordinator.moveDown()
        vm.searchText = "cli"
        await fixture.schedule.runSearches()
        #expect(names(coordinator) == ["clip.txt", "Clipboard", "clipping.pdf", "client.txt"])

        coordinator.moveDown()
        coordinator.moveDown()
        coordinator.moveDown()
        #expect(selectedName(coordinator) == "client.txt")

        vm.searchText = "clie"
        await fixture.schedule.runSearches()
        #expect(names(coordinator) == ["client.txt", "clip.txt"], "the new pick first, the old one in its place")
        #expect(selectedName(coordinator) == "client.txt")
    }

    /// Back on the first row by hand is no pick at all: the next Query lists
    /// in its usual order.
    @Test func movingBackToTheFirstRowPinsNothing() async throws {
        let files = FakeFileIndex(answers: [
            "cl": docs("clay.txt", "clip.txt"),
            "cli": docs("clipping.pdf", "clip.txt")
        ])
        let fixture = try makeFixture(fileIndex: files, disabling: [.emoji, .clipboardHistory])
        let coordinator = fixture.coordinator
        let vm = coordinator.subjectVM

        vm.searchText = "cl"
        await fixture.schedule.runSearches()
        coordinator.moveDown()
        coordinator.moveUp()

        vm.searchText = "cli"
        await fixture.schedule.runSearches()
        #expect(names(coordinator) == ["Clipboard", "clipping.pdf", "clip.txt"])
        #expect(vm.pinCount == 0)
    }

    /// Clearing the Query, ⌘E and Escape back, and the Panel opening again
    /// each forget the pick: the next Query lists in its usual order.
    @Test(arguments: ["cleared", "text", "reopened"])
    func aPickIsForgotten(by way: String) async throws {
        let files = FakeFileIndex(answers: [
            "cl": docs("clay.txt", "clip.txt"),
            "cli": docs("clipping.pdf", "clip.txt")
        ])
        let fixture = try makeFixture(fileIndex: files, disabling: [.emoji, .clipboardHistory])
        let coordinator = fixture.coordinator
        let vm = coordinator.subjectVM

        vm.searchText = "cl"
        await fixture.schedule.runSearches()
        coordinator.moveDown()
        coordinator.moveDown()
        #expect(selectedName(coordinator) == "clip.txt")

        switch way {
        case "cleared":
            vm.searchText = ""
            vm.searchText = "cl"
            await fixture.schedule.runSearches()
        case "text":
            coordinator.toggleTextSubjectEdit()
            coordinator.toggleTextSubjectEdit()
            #expect(coordinator.isTextMode)
            _ = coordinator.handleEscape()
        default:
            coordinator.reset()
        }

        vm.searchText = "cli"
        await fixture.schedule.runSearches()
        #expect(names(coordinator) == ["Clipboard", "clipping.pdf", "clip.txt"])
        #expect(selectedName(coordinator) == "Clipboard")
    }

    /// Enter acts on the pinned row, and the Card shows it.
    @Test func enterActsOnThePinnedRow() async throws {
        let fixture = try makeFixture(
            clipboard: ["clip one", "clip two"],
            disabling: [.emoji]
        )
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "clip"
        await fixture.schedule.runSearches()
        #expect(names(coordinator) == ["Clipboard", "clip one", "clip two"])
        coordinator.moveDown()
        coordinator.moveDown()

        coordinator.subjectVM.searchText = "clip t"
        await fixture.schedule.runSearches()
        #expect(names(coordinator).first == "clip two")
        #expect(coordinator.subjectVM.cardSubject?.displayName == "clip two")
        #expect(coordinator.submit() == [.paste(.text("clip two"))])
    }

    /// Enter acts on the row highlighted at that moment, after a re-rank too.
    @Test func enterActsOnTheFollowedRow() async throws {
        let fixture = try makeFixture(
            clipboard: ["clip one", "clip two"],
            disabling: [.emoji, .builtIns]
        )
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "clip"
        await fixture.schedule.runSearches()
        #expect(names(coordinator) == ["clip one", "clip two"])
        coordinator.moveDown()

        fixture.history.recordText("clip zero")
        await fixture.schedule.typingPaused()
        #expect(selectedName(coordinator) == "clip two")

        #expect(coordinator.submit() == [.paste(.text("clip two"))])
    }

    // MARK: - Ranking

    /// One list, ordered by score whatever the Source.
    @Test func rowsFromEverySourceAreOrderedByScore() async throws {
        let fixture = try makeFixture(
            files: [hit("/docs/clip", score: 0), hit("/clip/elsewhere.txt", score: FileHit.folderOnlyScore)],
            clipboard: ["clip this", "my clip"],
            disabling: [.emoji, .builtIns]
        )
        let vm = fixture.coordinator.subjectVM
        vm.searchText = "clip"
        await fixture.schedule.typingPaused()

        // 0 exact, 1 prefix, 13 substring at 3, 200 folder only.
        #expect(names(fixture.coordinator) == ["clip", "clip this", "my clip", "elsewhere.txt"])
    }

    @Test func theRankingIsOneScaleAcrossSources() throws {
        let emoji = try EmojiIndex.bundled().all
        let search = SourceSearch(
            query: "cat",
            searchFiles: { _ in [] },
            clipboard: [ClipboardItem(content: "the cat sat"), ClipboardItem(content: "category")],
            emoji: emoji,
            recentEmoji: []
        )

        let ranked = search.rank(files: [])

        #expect(ranked.map(\.score) == ranked.map(\.score).sorted())
        #expect(ranked.contains { if case .clipboard = $0.hit { true } else { false } })
        #expect(ranked.contains { if case .emoji = $0.hit { true } else { false } })
    }

    /// The Kind a Kind Word asks for scores below zero (`FileHit.kindScore`),
    /// so 📹 and a Clipboard Item that say "video" come after the videos;
    /// below the block they mix with the rest by score as ever.
    @Test func emojiAndClipboardGoBelowTheKindBlock() throws {
        let search = SourceSearch(
            query: "video",
            searchFiles: { _ in [] },
            clipboard: [ClipboardItem(content: "video")],
            emoji: try EmojiIndex.bundled().all,
            recentEmoji: []
        )
        let ranked = search.rank(files: [
            hit("/v/standup.mov", score: FileHit.kindScore),
            hit("/v/beach.mov", score: FileHit.kindScore + 1),
            hit("/v/VideoSlide.tsx", score: 1),
        ])

        func key(_ row: SourceSearch.Ranked) -> String {
            switch row.hit {
            case .file(let file): file.name
            case .clipboard: "clipboard"
            case .emoji: "emoji"
            }
        }
        let keys = ranked.map(key)
        #expect(Array(keys.prefix(2)) == ["standup.mov", "beach.mov"])
        #expect(keys.contains("emoji") && keys.contains("clipboard"))
        #expect(keys.firstIndex(of: "clipboard")! < keys.firstIndex(of: "VideoSlide.tsx")!,
                "the exact Clipboard Item still beats a prefix name below the block")
    }

    /// Clipboard and Emoji give three rows each at most; files are not capped
    /// below the File Index's own fifty.
    @Test func clipboardAndEmojiAreCappedAndFilesAreNot() async throws {
        let files = (0..<60).map { hit("/docs/cat \($0).txt", score: 1) }
        let fixture = try makeFixture(
            files: files,
            clipboard: (0..<10).map { "cat \($0)" },
            disabling: [.builtIns]
        )
        let vm = fixture.coordinator.subjectVM
        vm.searchText = "cat"
        await fixture.schedule.typingPaused()

        let hits = vm.sourceResults.map(\.hit)
        let fileCount = hits.filter { if case .file = $0 { true } else { false } }.count
        let clipboardCount = hits.filter { if case .clipboard = $0 { true } else { false } }.count
        let emojiCount = hits.filter { if case .emoji = $0 { true } else { false } }.count
        #expect(fileCount == SourceSearch.fileLimit)
        #expect(clipboardCount == SourceSearch.clipboardCap)
        #expect(emojiCount == SourceSearch.emojiCap)
    }

    /// An image's name is only its timestamp: nothing to match on.
    @Test func onlyTextClipboardItemsAreSearched() async throws {
        let fixture = try makeFixture(disabling: [.emoji, .builtIns])
        fixture.history.recordImage(Data([0x89, 0x50, 0x4E, 0x47]))
        let vm = fixture.coordinator.subjectVM
        vm.searchText = "image"
        await fixture.schedule.typingPaused()

        #expect(vm.results.isEmpty)
    }

    // MARK: - Sources

    @Test func aSwitchedOffSourceGivesNoRows() async throws {
        let fixture = try makeFixture(
            files: [hit("/docs/clipping.pdf", score: 1)],
            clipboard: ["clip this"],
            disabling: [.clipboardHistory, .emoji, .builtIns, .applications]
        )
        let vm = fixture.coordinator.subjectVM
        vm.searchText = "clip"
        #expect(vm.results.isEmpty, "no Built-ins")

        await fixture.schedule.typingPaused()

        #expect(names(fixture.coordinator) == ["clipping.pdf"], "the File Index answers for its own folders")
    }

    @Test func switchedOnSourcesAllContribute() async throws {
        let fixture = try makeFixture(clipboard: ["clip this"])
        let vm = fixture.coordinator.subjectVM
        vm.searchText = "clip"
        await fixture.schedule.typingPaused()

        #expect(vm.results.first?.displayName == "Clipboard")
        #expect(vm.sourceResults.contains { $0.subject.clipboardItem?.content == "clip this" })
        #expect(vm.sourceResults.contains { $0.subject.emoji != nil })
    }

    /// A path is a path and nothing else: no list below it.
    @Test func aPathQueryHasNoListBelowIt() async throws {
        let file = try fixtureFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let fixture = try makeFixture(files: [hit("/docs/clipping.pdf", score: 1)], clipboard: ["/tmp"])
        let vm = fixture.coordinator.subjectVM

        vm.searchText = file.path
        await fixture.schedule.typingPaused()

        #expect(names(fixture.coordinator) == ["clip notes.txt"])
        #expect(fixture.files.calls == 0)
        #expect(vm.sourceResults.isEmpty)
    }

    // MARK: - Rows

    @Test func eachRowSaysWhichSourceItCameFrom() async throws {
        let fixture = try makeFixture(
            files: [hit("/docs/clipping.pdf", score: 1)],
            clipboard: ["clip this"],
            disabling: [.builtIns]
        )
        let vm = fixture.coordinator.subjectVM
        vm.searchText = "clip"
        await fixture.schedule.typingPaused()

        let rows = fixture.coordinator.currentResults
        let file = try #require(rows.first { $0.id == "file:/docs/clipping.pdf" })
        #expect(file.subtitle == "/docs")
        #expect(file.thumbnailURL == URL(fileURLWithPath: "/docs/clipping.pdf"))
        let clipboard = try #require(rows.first { $0.id.hasPrefix("clipboard:") })
        #expect(clipboard.subtitle.hasPrefix("Clipboard · "))
        let emoji = try #require(rows.first { $0.id.hasPrefix("emoji:") })
        #expect(emoji.subtitle == "Emoji")
    }

    // MARK: - Enter and Tab

    @Test func enterOnAFileOpensItAndMakesItTheLastSubject() async throws {
        let file = try fixtureFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let fixture = try makeFixture(
            files: [hit(file.path, score: 1)],
            disabling: [.emoji, .clipboardHistory]
        )
        let coordinator = fixture.coordinator
        coordinator.enterEmojiMode()
        coordinator.submit()
        #expect(coordinator.lastSubject != nil)
        coordinator.reset()

        coordinator.acceptTypedText("clip")
        await fixture.schedule.typingPaused()
        #expect(names(coordinator) == ["Clipboard", "clip notes.txt"])
        coordinator.moveDown()

        #expect(coordinator.submit() == [.hide, .open(file.standardizedFileURL)])
        #expect(coordinator.lastSubject?.url == file.standardizedFileURL, "the file, in place of the Emoji")
    }

    @Test func tabOnAFileOpensItsActionsAsAFileSubject() async throws {
        let file = try fixtureFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let fixture = try makeFixture(
            files: [hit(file.path, score: 1)],
            disabling: [.emoji, .clipboardHistory, .builtIns]
        )
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "clip"
        await fixture.schedule.typingPaused()

        coordinator.advancePhase()

        #expect(coordinator.phase == .pickingAction)
        guard case .file(let contentType)? = coordinator.selectedSubject?.kind else {
            Issue.record("expected a file Subject, got \(String(describing: coordinator.selectedSubject?.kind))")
            return
        }
        #expect(contentType.conforms(to: .plainText))
        #expect(coordinator.actionVM.filteredActions.contains { $0.name == "Share…" })

        coordinator.retreatPhase()
        #expect(coordinator.phase == .searchingSubject)
    }

    /// A file the File Index still lists but the disk no longer has is not
    /// acted on.
    @Test func aFileThatIsGoneIsNotActedOn() async throws {
        let fixture = try makeFixture(
            files: [hit("/no/such/place/clip zzqqzz.txt", score: 1)],
            disabling: [.emoji, .clipboardHistory, .builtIns]
        )
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "clip"
        await fixture.schedule.typingPaused()

        #expect(coordinator.submit().isEmpty)
        coordinator.advancePhase()
        #expect(coordinator.phase == .searchingSubject)
    }

    @Test func enterOnAClipboardItemPastesItAndMakesItTheLastSubject() async throws {
        let fixture = try makeFixture(
            clipboard: ["newest", "clip this"],
            disabling: [.emoji, .builtIns]
        )
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "clip"
        await fixture.schedule.typingPaused()

        #expect(coordinator.submit() == [.paste(.text("clip this"))])
        #expect(coordinator.lastSubject?.clipboardItem?.content == "clip this")
        #expect(fixture.history.items.first?.content == "clip this", "a pasted entry becomes the newest")
    }

    @Test func tabOnAClipboardItemOpensItsActionsAndShiftTabComesBack() async throws {
        let fixture = try makeFixture(clipboard: ["clip this"], disabling: [.emoji, .builtIns])
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "clip"
        await fixture.schedule.typingPaused()

        coordinator.advancePhase()
        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.selectedClipboardItem?.content == "clip this")
        #expect(coordinator.actionVM.filteredActions.contains { $0.name == "Paste" })

        coordinator.retreatPhase()
        #expect(coordinator.phase == .searchingSubject, "back to the search it came from, not the Clipboard browser")
        #expect(names(coordinator) == ["clip this"])
    }

    @Test func enterOnAnEmojiInsertsItAndMakesItRecentAndTheLastSubject() async throws {
        let fixture = try makeFixture(disabling: [.clipboardHistory, .builtIns])
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "paperclip"
        await fixture.schedule.typingPaused()
        let row = try #require(coordinator.subjectVM.sourceResults.first)
        let emoji = try #require(row.subject.emoji)

        #expect(coordinator.submit() == [.paste(.text(emoji.string))])
        #expect(coordinator.lastSubject?.emoji == emoji)
        #expect(fixture.recents.strings.first == row.emojiBase?.string)
    }

    @Test func tabOnAnEmojiOpensItsActionsAndShiftTabComesBack() async throws {
        let fixture = try makeFixture(disabling: [.clipboardHistory, .builtIns])
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "paperclip"
        await fixture.schedule.typingPaused()

        coordinator.advancePhase()
        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.selectedSubject?.emoji != nil)

        coordinator.retreatPhase()
        #expect(coordinator.phase == .searchingSubject, "back to the search, not the Emoji grid")
    }

    // MARK: - "No results"

    /// Zero app matches is not yet "No results": the list below the apps has
    /// not answered — and its word answer on the keystroke is not all of it,
    /// because the settled pass can still find what a Passage says. Once that
    /// has landed empty too, the claim is true.
    @Test func noResultsWaitsForTheListBelowTheApps() async throws {
        let (index, root) = try await populatedIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(index: index)
        let coordinator = fixture.coordinator

        coordinator.subjectVM.searchText = "zzqqzz"
        #expect(!coordinator.canReportNoResults)
        #expect(!coordinator.hasNoSubjectMatch)

        await fixture.schedule.runSearches()
        #expect(!coordinator.canReportNoResults, "the words found nothing; the settled pass is still to come")
        #expect(!coordinator.hasNoSubjectMatch)

        await fixture.schedule.typingPaused()
        #expect(coordinator.canReportNoResults)
        #expect(coordinator.hasNoSubjectMatch)
        index.stop()
    }

    /// While a newer Query is out, the previous list stays and nothing says
    /// "No results"; the claim waits for this Query's own settled, empty
    /// answer.
    @Test func noResultsIsNeverClaimedForAQueryStillOut() async throws {
        let (index, root) = try await populatedIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(
            fileIndex: FakeFileIndex(answers: ["zz": docs("zz top.txt")]),
            index: index,
            disabling: [.emoji, .clipboardHistory]
        )
        let coordinator = fixture.coordinator

        coordinator.subjectVM.searchText = "zz"
        await fixture.schedule.runSearches()
        #expect(names(coordinator) == ["zz top.txt"])

        coordinator.subjectVM.searchText = "zzq"
        #expect(names(coordinator) == ["zz top.txt"], "the previous list, not a blank one")
        #expect(!coordinator.canReportNoResults)
        #expect(!coordinator.hasNoSubjectMatch)

        await fixture.schedule.typingPaused()
        #expect(names(coordinator).isEmpty)
        #expect(coordinator.canReportNoResults)
        #expect(coordinator.hasNoSubjectMatch)
        index.stop()
    }

    @Test func aQueryOnlyTheListAnswersIsNotANoMatch() async throws {
        let (index, root) = try await populatedIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(files: [hit("/docs/zzqqzz.txt", score: 0)], index: index)
        let coordinator = fixture.coordinator

        coordinator.subjectVM.searchText = "zzqqzz"
        await fixture.schedule.runSearches()

        #expect(names(coordinator) == ["zzqqzz.txt"])
        #expect(!coordinator.hasNoSubjectMatch)
        index.stop()
    }

    // MARK: - An empty Query

    /// Clearing the Query takes the list away, and a search still out for the
    /// Query that was there does not bring it back.
    @Test func clearingTheQueryTakesTheListAway() async throws {
        let fixture = try makeFixture(
            files: docs("clipping.pdf"),
            disabling: [.emoji, .clipboardHistory, .builtIns]
        )
        let vm = fixture.coordinator.subjectVM
        vm.searchText = "clip"
        await fixture.schedule.runSearches()
        #expect(names(fixture.coordinator) == ["clipping.pdf"])

        vm.searchText = "clipp"
        vm.searchText = ""
        #expect(vm.results.isEmpty)
        #expect(vm.sourceResults.isEmpty)

        await fixture.schedule.typingPaused()
        #expect(vm.results.isEmpty)
        #expect(fixture.files.asked == ["clip"])
    }

    // MARK: - ⌘E

    /// A Query turned into text stays text when the list lands after it, and
    /// Escape comes back to the list without asking again.
    @Test func aLateListDoesNotUndoACmdE() async throws {
        let fixture = try makeFixture(
            files: docs("clipping.pdf"),
            disabling: [.emoji, .clipboardHistory]
        )
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "clip"
        coordinator.toggleTextSubjectEdit()
        coordinator.toggleTextSubjectEdit()
        #expect(coordinator.isTextMode)

        await fixture.schedule.typingPaused()
        #expect(coordinator.isTextMode)

        _ = coordinator.handleEscape()
        await fixture.schedule.typingPaused()
        #expect(names(coordinator) == ["Clipboard", "clipping.pdf"])
        #expect(fixture.files.asked == ["clip", "clip"], "the keystroke and the pause, and nothing for Escape")
    }
}
