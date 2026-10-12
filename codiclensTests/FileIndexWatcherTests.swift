import CoreServices
import Foundation
import Synchronization
import Testing
@testable import codiclens

/// FSEvents itself, over a temporary folder: that a change arrives as a batch
/// naming the file, and that `FileIndex` turns it into a searchable row. Every
/// wait here is on the event, never on a clock; a test that hangs has failed,
/// and the time limit catches it.
@Suite(.timeLimit(.minutes(1)))
struct FileIndexWatcherTests {

    @Test func aCreatedFileArrivesByName() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let target = folder.path("hello.txt")
        let queue = DispatchQueue(label: "test.file-index-watcher")
        let resumed = Mutex(false)

        var watcher: FileIndexWatcher?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            watcher = FileIndexWatcher(paths: [folder.path], queue: queue) { events in
                guard events.contains(where: { $0.path == target }) else { return }
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume() }
            }
            #expect(watcher != nil)
            try? folder.makeFile("hello.txt")
        }
        watcher?.stop()
    }

    @MainActor
    @Test func aFileCreatedAfterStartBecomesSearchable() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.makeFile("Source/existing.txt")
        let defaults = ThrowawayDefaults()
        defaults.set([folder.path("Source")], forKey: "codiclens.sources.folders")
        let index = FileIndex(
            databaseURL: folder.url.appendingPathComponent("FileIndex.sqlite"),
            sources: SourceStore(defaults: defaults)
        )
        defer { index.stop() }

        index.start()
        // Both rows in, and the file's contents read by the backfill.
        await waitUntil(index) { index.counts[folder.path("Source")] == SourceCounts(indexed: 2, total: 2) }
        #expect(index.search("existing").map(\.name) == ["existing.txt"])

        try folder.makeFile("Source/arrived later.txt", contents: "kvittering for husleje")
        await waitUntil(index) { index.counts[folder.path("Source")] == SourceCounts(indexed: 3, total: 3) }
        #expect(index.search("arrived").map(\.name) == ["arrived later.txt"])
        let byWords = index.search("kvittering")
        #expect(byWords.map(\.name) == ["arrived later.txt"], "a changed file's words are read straight away")
        #expect(byWords.first?.passage?.excerpt == "kvittering for husleje")
    }

    /// Waits until `condition` holds, looking again each time the File Index
    /// publishes. `generation` moves every time rows land and their counts
    /// have been read.
    @MainActor
    private func waitUntil(_ index: FileIndex, _ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = index.generation } onChange: { continuation.resume() }
            }
        }
    }
}
