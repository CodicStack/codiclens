import Foundation
import Testing
@testable import codiclens

/// The File Index over temporary folders standing in for Downloads and
/// Desktop, as Setup's Folders row hands them over: nothing read before
/// Allow, a folder macOS refuses, and that folder read once it is allowed.
/// A folder with no permissions stands in for macOS refusing one: listing
/// it fails the same way, and nothing here asks macOS anything.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FolderAccessTests {
    let folder: TemporaryFolder
    let defaults = ThrowawayDefaults()

    init() throws {
        folder = try TemporaryFolder()
        try folder.makeFile("Downloads/receipt.txt")
        try folder.makeFile("Desktop/notes.txt")
    }

    /// As the Sources keep them: `/var`, not `/private/var`.
    private var downloads: String { URL(fileURLWithPath: folder.path("Downloads")).standardizedFileURL.path }
    private var desktop: String { URL(fileURLWithPath: folder.path("Desktop")).standardizedFileURL.path }

    private func fileIndex(_ sources: SourceStore) -> FileIndex {
        FileIndex(databaseURL: folder.url.appendingPathComponent("FileIndex.sqlite"), sources: sources)
    }

    private func foldersRow(_ sources: SourceStore, _ index: FileIndex) -> FoldersRow {
        FoldersRow(sources: sources, folders: [downloads, desktop], isDenied: { index.deniedFolders.contains($0) })
    }

    /// macOS refuses `path` until `allow` is called.
    private func refuse(_ path: String) {
        chmod(path, 0)
    }

    private func allow(_ path: String) {
        chmod(path, 0o755)
    }

    @Test func theFileIndexReadsNoFolderBeforeAllowAndBothAfter() async {
        defer { folder.remove() }
        let sources = SourceStore(defaults: defaults)
        let index = fileIndex(sources)
        defer { index.stop() }
        let row = foldersRow(sources, index)

        index.start()
        await waitUntil(index) { index.generation > 0 }
        #expect(index.counts.isEmpty)
        #expect(index.readingFolders.isEmpty)
        #expect(index.search("receipt").isEmpty)

        row.allow()

        await waitUntil(index) {
            index.counts[downloads]?.total == 2 && index.counts[desktop]?.total == 2
        }
        #expect(index.search("receipt").map(\.name) == ["receipt.txt"])
        #expect(index.search("notes").map(\.name) == ["notes.txt"])
        #expect(row.deniedNames.isEmpty)
    }

    @Test func aFolderMacOSRefusesShowsNoAccessAndIsReadOnceAllowed() async {
        refuse(desktop)
        defer {
            allow(desktop)
            folder.remove()
        }
        let sources = SourceStore(defaults: defaults)
        let index = fileIndex(sources)
        defer { index.stop() }
        let row = foldersRow(sources, index)
        let page = SourcesPage(
            store: sources, counts: { _ in nil }, isReading: { _ in false },
            isDenied: { index.deniedFolders.contains($0) }
        )
        index.start()

        row.allow()

        await waitUntil(index) { !index.deniedFolders.isEmpty && index.counts[downloads]?.total == 2 }
        #expect(row.deniedNames == ["Desktop"])
        #expect(page.folderRows.map(\.hasNoAccess) == [false, true])
        #expect(index.search("receipt").map(\.name) == ["receipt.txt"], "the other folder is read")

        // Turned on in Privacy & Security, and the app comes back to the front.
        allow(desktop)
        index.recheckAccess()

        await waitUntil(index) { index.deniedFolders.isEmpty && index.counts[desktop]?.total == 2 }
        #expect(index.search("notes").map(\.name) == ["notes.txt"])
        #expect(row.deniedNames.isEmpty)
        #expect(page.folderRows.map(\.hasNoAccess) == [false, false])
    }

    /// A refused folder is never taken as read: the next launch tries it
    /// again rather than waiting for FSEvents to mention its files.
    @Test func aRefusedFolderIsTriedAgainAtTheNextLaunch() async {
        refuse(desktop)
        defer {
            allow(desktop)
            folder.remove()
        }
        let sources = SourceStore(defaults: defaults)
        let first = fileIndex(sources)
        first.start()
        foldersRow(sources, first).allow()
        await waitUntil(first) { first.deniedFolders == [desktop] && first.counts[downloads]?.total == 2 }
        first.stop()

        allow(desktop)
        let next = fileIndex(SourceStore(defaults: defaults))
        defer { next.stop() }
        next.start()

        await waitUntil(next) { next.counts[desktop]?.total == 2 }
        #expect(next.search("notes").map(\.name) == ["notes.txt"])
        #expect(next.deniedFolders.isEmpty)
    }

    /// Waits until `condition` holds, looking again each time the File Index
    /// publishes rows or a refusal.
    private func waitUntil(_ index: FileIndex, _ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = index.generation
                    _ = index.deniedFolders
                } onChange: { continuation.resume() }
            }
        }
    }
}

