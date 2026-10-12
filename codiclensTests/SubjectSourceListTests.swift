import AppKit
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import codiclens

/// The list below the apps in Subject search: File Results, Clipboard Items
/// and Emoji, ranked against each other, landing once as typing pauses — see
/// `docs/adr/0012-files-in-subject-search-text-mode-is-cmd-e.md`.
///
/// The File Index is a stand-in and the debounce is not waited out: each test
/// runs the debounced step, `searchSources()`, itself.
@MainActor
struct SubjectSourceListTests {

    /// A File Index stand-in whose answer can change between two searches,
    /// and which counts how often it was asked.
    final class FakeFileIndex: Sendable {
        private let state: Mutex<(hits: [FileHit], calls: Int)>

        init(_ hits: [FileHit] = []) {
            state = Mutex((hits, 0))
        }

        var hits: [FileHit] {
            get { state.withLock { $0.hits } }
            set { state.withLock { $0.hits = newValue } }
        }

        var calls: Int { state.withLock { $0.calls } }

        var search: FileIndex.Search {
            { [self] _ in
                state.withLock { state in
                    state.calls += 1
                    return state.hits
                }
            }
        }
    }

    private struct Fixture {
        let coordinator: CommandCoordinator
        let history: ClipboardHistory
        let files: FakeFileIndex
        let sources: SourceStore
        let recents: EmojiRecents
    }

    private func makeFixture(
        files: [FileHit] = [],
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
            preferences: EmojiPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        let sources = SourceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        for kind in disabled {
            sources.setEnabled(false, for: Source(kind: kind, isEnabled: true).id)
        }
        let fileIndex = FakeFileIndex(files)
        let coordinator = CommandCoordinator(
            runner: RecordingEffectRunner(),
            history: history,
            emojiVM: emojiVM,
            index: index ?? inertAppIndex,
            sources: sources,
            searchFiles: fileIndex.search
        )
        return Fixture(coordinator: coordinator, history: history, files: fileIndex, sources: sources, recents: recents)
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

    // MARK: - Landing

    /// The apps answer on the keystroke and are on top; the list lands below
    /// them and moves nothing above it.
    @Test func theAppsStayOnTopAndUnchangedWhenTheListLands() async throws {
        let fixture = try makeFixture(
            files: [hit("/docs/clipping.pdf", score: 1)],
            disabling: [.emoji, .clipboardHistory]
        )
        let vm = fixture.coordinator.subjectVM

        vm.searchText = "clip"
        let appsBefore = vm.results.map(\.id)
        let rowsBefore = fixture.coordinator.currentResults.map(\.id)
        #expect(names(fixture.coordinator) == ["Clipboard"], "the Built-in, on the keystroke")

        await vm.searchSources()

        #expect(names(fixture.coordinator) == ["Clipboard", "clipping.pdf"])
        #expect(Array(vm.results.prefix(appsBefore.count).map(\.id)) == appsBefore)
        #expect(Array(fixture.coordinator.currentResults.prefix(rowsBefore.count).map(\.id)) == rowsBefore)
        #expect(vm.selectedIndex == 0, "the selection did not move")
    }

    @Test func theListLandsOnceAndIsNeverRankedAgainForTheSameQuery() async throws {
        let fixture = try makeFixture(
            files: [hit("/docs/clip one.txt", score: 1)],
            disabling: [.emoji, .clipboardHistory]
        )
        let vm = fixture.coordinator.subjectVM
        vm.searchText = "clip"
        await vm.searchSources()
        let landed = fixture.coordinator.currentResults.map(\.id)

        fixture.files.hits = [hit("/docs/clip two.txt", score: 0), hit("/docs/clip one.txt", score: 1)]
        await vm.searchSources()

        #expect(fixture.coordinator.currentResults.map(\.id) == landed)
    }

    /// A new keystroke withdraws the list: rows that answered the previous
    /// Query are not an answer to this one. The next pause brings the new one.
    @Test func aNewKeystrokeWithdrawsTheListUntilItsOwnLands() async throws {
        let fixture = try makeFixture(
            files: [hit("/docs/clipping.pdf", score: 1)],
            disabling: [.emoji, .clipboardHistory]
        )
        let vm = fixture.coordinator.subjectVM
        vm.searchText = "clip"
        await vm.searchSources()
        #expect(vm.results.count == 2)

        vm.searchText = "clipp"
        #expect(names(fixture.coordinator).isEmpty, "Clipboard does not match, and the old list is gone")
        #expect(!vm.hasAnswered)

        await vm.searchSources()
        #expect(names(fixture.coordinator) == ["clipping.pdf"])
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
        await vm.searchSources()

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

        let ranked = search.rank()

        #expect(ranked.map(\.score) == ranked.map(\.score).sorted())
        #expect(ranked.contains { if case .clipboard = $0.hit { true } else { false } })
        #expect(ranked.contains { if case .emoji = $0.hit { true } else { false } })
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
        await vm.searchSources()

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
        await vm.searchSources()

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

        await vm.searchSources()

        #expect(names(fixture.coordinator) == ["clipping.pdf"], "the File Index answers for its own folders")
    }

    @Test func switchedOnSourcesAllContribute() async throws {
        let fixture = try makeFixture(clipboard: ["clip this"])
        let vm = fixture.coordinator.subjectVM
        vm.searchText = "clip"
        await vm.searchSources()

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
        await vm.searchSources()

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
        await vm.searchSources()

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

    @Test func enterOnAFileOpensItAndEndsTheLastSubject() async throws {
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
        await coordinator.subjectVM.searchSources()
        #expect(names(coordinator) == ["Clipboard", "clip notes.txt"])
        coordinator.moveDown()

        #expect(coordinator.submit() == [.hide, .open(file.standardizedFileURL)])
        #expect(coordinator.lastSubject == nil, "a file is never the Last Subject")
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
        await coordinator.subjectVM.searchSources()

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
        await coordinator.subjectVM.searchSources()

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
        await coordinator.subjectVM.searchSources()

        #expect(coordinator.submit() == [.paste(.text("clip this"))])
        #expect(coordinator.lastSubject?.clipboardItem?.content == "clip this")
        #expect(fixture.history.items.first?.content == "clip this", "a pasted entry becomes the newest")
    }

    @Test func tabOnAClipboardItemOpensItsActionsAndShiftTabComesBack() async throws {
        let fixture = try makeFixture(clipboard: ["clip this"], disabling: [.emoji, .builtIns])
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "clip"
        await coordinator.subjectVM.searchSources()

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
        await coordinator.subjectVM.searchSources()
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
        await coordinator.subjectVM.searchSources()

        coordinator.advancePhase()
        #expect(coordinator.phase == .pickingAction)
        #expect(coordinator.selectedSubject?.emoji != nil)

        coordinator.retreatPhase()
        #expect(coordinator.phase == .searchingSubject, "back to the search, not the Emoji grid")
    }

    // MARK: - "No results"

    /// Zero app matches is not yet "No results": the list below the apps has
    /// not answered. Once it has, and it is empty too, the claim is true.
    @Test func noResultsWaitsForTheListBelowTheApps() async throws {
        let (index, root) = try await populatedIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(index: index)
        let coordinator = fixture.coordinator

        coordinator.subjectVM.searchText = "zzqqzz"
        #expect(!coordinator.canReportNoResults)
        #expect(!coordinator.hasNoSubjectMatch)

        await coordinator.subjectVM.searchSources()
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
        await coordinator.subjectVM.searchSources()

        #expect(names(coordinator) == ["zzqqzz.txt"])
        #expect(!coordinator.hasNoSubjectMatch)
        index.stop()
    }

    // MARK: - ⌘E

    /// A Query turned into text stays text when the list lands late, and
    /// Escape comes back to the list without asking again.
    @Test func aLateListDoesNotUndoACmdE() async throws {
        let fixture = try makeFixture(
            files: [hit("/docs/clipping.pdf", score: 1)],
            disabling: [.emoji, .clipboardHistory]
        )
        let coordinator = fixture.coordinator
        coordinator.subjectVM.searchText = "clip"
        coordinator.toggleTextSubjectEdit()
        coordinator.toggleTextSubjectEdit()
        #expect(coordinator.isTextMode)

        await coordinator.subjectVM.searchSources()
        #expect(coordinator.isTextMode)

        _ = coordinator.handleEscape()
        #expect(names(coordinator) == ["Clipboard", "clipping.pdf"])
        #expect(fixture.files.calls == 1)
    }
}
