import Foundation
import Synchronization
import Testing
@testable import codiclens

/// The File Index with search by meaning switched on, as the app runs it: its
/// own queue, the switch, the backfill, `searchSettled`, and off. Over
/// `KeywordEmbedder` for both helpers and a temporary Source.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MeaningFileIndexTests {
    private final class Setup {
        let folder: TemporaryFolder
        let index: FileIndex
        let indexing = KeywordEmbedder()
        let query: any QueryEncoder

        init(query: (any QueryEncoder)? = nil, isOn: Bool = true) throws {
            folder = try TemporaryFolder()
            try folder.makeFolder("Source")
            try folder.makeFolder("models")
            for file in StubDownloader.files {
                try StubDownloader.contents[file.name]!.write(to: folder.url.appendingPathComponent("models/\(file.name)"))
            }
            let defaults = ThrowawayDefaults()
            defaults.set([folder.path("Source")], forKey: "codiclens.sources.folders")
            let files = ModelFiles(folder: folder.url.appendingPathComponent("models"), files: StubDownloader.files,
                                   downloader: StubDownloader())
            let query = query ?? KeywordEmbedder()
            self.query = query
            index = FileIndex(
                databaseURL: folder.url.appendingPathComponent("FileIndex.sqlite"),
                sources: SourceStore(defaults: defaults),
                meaning: MeaningSettings(files: files, switch: MeaningSettings.Switch(isOn: isOn, save: { _ in }),
                                         isSupported: true),
                indexEmbedder: indexing,
                queryEncoder: query
            )
        }

        deinit {
            folder.remove()
        }
    }

    @Test func switchedOnItEmbedsEverythingAndTheSettledSearchFindsByMeaning() async throws {
        let setup = try Setup()
        let index = setup.index
        defer { index.stop() }
        try setup.folder.makeFile("Source/notes.md", contents: "Blend banana and berries for the smoothie.")
        try TestMedia.picture(at: setup.folder.path("Source/seaside.png"))
        for number in 0..<24 { try setup.folder.makeFile("Source/n\(number).md", contents: "ordinary text \(number)") }

        index.start()
        await waitUntil(index) { index.meaningCounts.files == 26 && index.meaningCounts.embedded == 26 }
        #expect(index.meaningCounts.vectors == 26)
        #expect(index.meaning.status == .ready(index.meaningCounts))

        let found = await index.searchSettled("smoothie opskrift")
        #expect(found.first?.name == "notes.md")
        #expect(found.first?.meaning == .text)
        let picture = await index.searchSettled("beach")
        #expect(picture.first?.name == "seaside.png")
        #expect(picture.first?.meaning == .image)

        index.meaning.setEnabled(false)
        let words = await index.searchSettled("beach")
        #expect(words.isEmpty, "off: the word search alone")
        #expect(index.meaningCounts == MeaningCounts())
        // Told on the File Index's queue, after the switch.
        while setup.indexing.shutdowns.withLock({ $0 }) == 0 { await Task.yield() }
    }

    @Test func aNewerSettledSearchWinsOverOneStillWaitingForItsVector() async throws {
        let gated = GatedEncoder()
        let setup = try Setup(query: gated)
        let index = setup.index
        defer { index.stop() }
        try setup.folder.makeFile("Source/notes.md", contents: "the smoothie")
        index.start()
        await waitUntil(index) { index.meaningCounts.files == 1 && index.meaningCounts.embedded == 1 }

        gated.isHeld.withLock { $0 = true }
        let older = Task { await index.searchSettled("smoothie") }
        while gated.waiting.withLock({ $0 }) == 0 { await Task.yield() }
        gated.isHeld.withLock { $0 = false }
        let newer = await index.searchSettled("smoothie")
        gated.open()

        #expect(newer.map(\.name) == ["notes.md"])
        #expect(await older.value.isEmpty, "the older Query's answer is dropped")

        let cancelled = Task { await index.searchSettled("smoothie") }
        cancelled.cancel()
        #expect(await cancelled.value.isEmpty)
    }

    /// With search by meaning off the settled search is the word search with
    /// the last word a prefix, so the pause changes none of the rows the
    /// keystroke put there.
    @Test func switchedOffTheSettledPassListsWhatTheKeystrokeDid() async throws {
        let setup = try Setup(isOn: false)
        let index = setup.index
        defer { index.stop() }
        try setup.folder.makeFile("Source/notes.md", contents: "The invoice for March is paid.")
        try setup.folder.makeFile("Source/invoice 2024.txt", contents: "numbers")
        try setup.folder.makeFile("Source/recipe.md", contents: "Blend banana and berries.")
        index.start()
        await waitUntil(index) { index.search("invoice").count == 2 }

        let schedule = HeldSearchSchedule()
        let sources = SourceStore(defaults: ThrowawayDefaults())
        for kind in [Source.Kind.emoji, .clipboardHistory, .builtIns] {
            sources.setEnabled(false, for: Source(kind: kind, isEnabled: true).id)
        }
        let coordinator = CommandCoordinator.isolated(
            sources: sources, searchFiles: index.searcher, searchSettled: index.settledSearcher, searchSchedule: schedule
        )
        coordinator.subjectVM.searchText = "invoice"
        await schedule.runSearches()
        let typed = coordinator.currentResults.map(\.id)
        #expect(typed.count == 2)

        await schedule.typingPaused()
        #expect(coordinator.currentResults.map(\.id) == typed)
    }

    /// The Panel's hold reaches the query encoder only with search by
    /// meaning on.
    @Test func theQueryEncoderIsHeldOnlyWithMeaningOn() async throws {
        let encoder = KeywordEmbedder()
        let setup = try Setup(query: encoder)
        let index = setup.index
        defer { index.stop() }
        index.holdQueryEncoder()
        index.releaseQueryEncoder()

        try setup.folder.makeFile("Source/notes.md", contents: "the smoothie")
        index.start()
        await waitUntil(index) { index.meaningCounts.embedded == 1 }
        index.holdQueryEncoder()
        while encoder.holds.withLock({ $0 }) == 0 { await Task.yield() }
        #expect(encoder.holds.withLock { $0 } == 1, "the hold before the switch took did nothing")
    }

    private func waitUntil(_ index: FileIndex, _ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = index.generation
                    _ = index.meaningCounts
                } onChange: { continuation.resume() }
            }
        }
    }
}

/// A query encoder that, while held, keeps each request waiting until
/// `open()`.
final class GatedEncoder: QueryEncoder, @unchecked Sendable {
    let isHeld = Mutex(false)
    let waiting = Mutex(0)
    private let gates = Mutex<[CheckedContinuation<Void, Never>]>([])

    func embedQuery(_ text: String, code: Bool) async throws -> [Float] {
        if isHeld.withLock({ $0 }) {
            await withCheckedContinuation { continuation in
                gates.withLock { $0.append(continuation) }
                waiting.withLock { $0 += 1 }
            }
        }
        return KeywordEmbedder.vector(for: text)
    }

    func open() {
        for gate in gates.withLock({ gates in defer { gates = [] }; return gates }) { gate.resume() }
    }

    func hold() async throws {}
    func release() async {}
    func shutdown() async {}
}
