import CoreServices
import Foundation
import Synchronization
import Testing
@testable import codiclens

/// A launch catching up by FSEvents replay instead of a crawl: the event ID
/// and per-root volumes the index keeps, when a root has to be crawled
/// after all, and a real replay over a temporary folder. A "launch" is a
/// fresh `FileIndexer` over the same database, as the app makes one.
@Suite(.timeLimit(.minutes(1)))
struct FileIndexCatchUpTests {

    private final class Fixture {
        let folder: TemporaryFolder
        let url: URL
        var writer: FileIndexWriter!
        /// The roots crawled, in order, across every launch.
        var crawled: [String] = []
        /// What `volumeID` answers for a root, by its path relative to the folder.
        var volumes: [String: String] = [:]

        init() throws {
            folder = try TemporaryFolder()
            url = folder.url.appendingPathComponent("FileIndex.sqlite")
            writer = try FileIndexWriter(url: url)
        }

        deinit {
            writer = nil
            folder.remove()
        }

        func path(_ relative: String) -> String { folder.path(relative) }

        func relative(_ path: String) -> String { String(path.dropFirst(folder.path.count + 1)) }

        /// A fresh indexer over the same database, as at an app launch.
        func launch(rules: FileIndexRules = .defaults) -> FileIndexer {
            FileIndexer(
                writer: writer,
                rules: rules,
                volumeID: { [unowned self] path in volumes[relative(path)] ?? "volume" },
                onProgress: { [unowned self] progress in
                    if case .reading(let source, true) = progress { crawled.append(relative(source)) }
                }
            )
        }

        /// Sets the Sources as `FileIndex` does at launch, crawls what that
        /// asks for, and returns those roots, relative.
        @discardableResult
        func start(_ indexer: FileIndexer, _ roots: [String], disabled: Set<String> = []) throws -> Set<String> {
            let toCrawl = try indexer.setSources(roots.map { (path: path($0), isEnabled: !disabled.contains($0)) })
            for root in toCrawl { try indexer.crawl(root) }
            return Set(toCrawl.map(relative))
        }

        var indexed: Set<String> {
            get throws { Set(try writer.rows(inTree: folder.path).map { relative($0.path) }) }
        }
    }

    private static func event(_ path: String, _ flags: Int = 0, id: FSEventStreamEventId) -> FileIndexWatcher.Event {
        FileIndexWatcher.Event(path: path, flags: FSEventStreamEventFlags(flags), id: id)
    }

    // MARK: - The event ID

    @Test func theLastEventOfABatchIsStoredAndOutlivesTheConnection() throws {
        let f = try Fixture()
        try f.folder.makeFile("A/a.txt")
        let indexer = f.launch()
        try f.start(indexer, ["A"])

        try indexer.handle([
            Self.event(f.path("A/a.txt"), id: 10),
            Self.event(f.path("A/b.txt"), id: 12),
            Self.event("/", kFSEventStreamEventFlagHistoryDone, id: 0)
        ])

        #expect(indexer.eventID == 12, "historyDone's ID is not a change")
        #expect(try f.writer.eventID() == 12)
        f.writer = try FileIndexWriter(url: f.url)
        #expect(try f.writer.eventID() == 12)
        #expect(try f.writer.caughtUpRoots() == [f.path("A"): "volume"])
    }

    @Test func theEndOfAReplayAloneMovesNothing() throws {
        let f = try Fixture()
        let indexer = f.launch()
        try f.start(indexer, ["A"])
        let before = try f.writer.eventID()

        try indexer.handle([Self.event("/", kFSEventStreamEventFlagHistoryDone, id: 99)])

        #expect(try f.writer.eventID() == before, "nothing but the end of the replay")
    }

    // MARK: - When a launch crawls

    @Test func aFirstLaunchCrawlsEverySourceAndStoresWhereToReplayFrom() throws {
        let f = try Fixture()
        let before = FSEventsGetCurrentEventId()
        let indexer = f.launch()

        #expect(try f.start(indexer, ["A", "B"]) == ["A", "B"])

        let stored = try #require(try f.writer.eventID())
        #expect(stored >= before && stored <= FSEventsGetCurrentEventId())
        #expect(try f.writer.rulesFingerprint() == indexer.rulesFingerprint)
        #expect(indexer.rulesFingerprint.hasPrefix(FileIndexRules.defaults.fingerprint))
    }

    @Test func aLaunchWithNothingChangedCrawlsNothing() throws {
        let f = try Fixture()
        try f.folder.makeFile("A/a.txt")
        try f.start(f.launch(), ["A", "B"])
        let stored = try f.writer.eventID()

        let relaunched = f.launch()
        #expect(try f.start(relaunched, ["A", "B"]).isEmpty)
        #expect(relaunched.eventID == stored, "the watcher starts where the index was left")
        #expect(f.crawled.count == 2, "only the first launch's")
    }

    @Test func aReplayedBatchCatchesUpWithoutACrawl() throws {
        let f = try Fixture()
        try f.folder.makeFile("A/old.txt")
        try f.start(f.launch(), ["A"])
        try f.folder.removeItem("A/old.txt")
        try f.folder.makeFile("A/while closed.txt")

        let relaunched = f.launch()
        try f.start(relaunched, ["A"])
        try relaunched.handle([
            Self.event(f.path("A/old.txt"), kFSEventStreamEventFlagItemRemoved, id: relaunched.eventID + 1),
            Self.event(f.path("A/while closed.txt"), kFSEventStreamEventFlagItemCreated, id: relaunched.eventID + 2),
            Self.event("/", kFSEventStreamEventFlagHistoryDone, id: 0)
        ])

        #expect(try f.indexed == ["A", "A/while closed.txt"])
        #expect(f.crawled == ["A"], "the first launch's crawl, and no other")
    }

    @Test func aVolumeWhoseHistoryWasReplacedIsCrawled() throws {
        let f = try Fixture()
        try f.start(f.launch(), ["A", "B"])

        f.volumes["B"] = "a disk erased and restored"
        #expect(try f.start(f.launch(), ["A", "B"]) == ["B"])
        #expect(try f.start(f.launch(), ["A", "B"]).isEmpty, "caught up on the new volume")
    }

    @Test func aVolumeWithoutHistoryIsCrawledEveryLaunch() throws {
        let f = try Fixture()
        let launch = { [f] in
            FileIndexer(writer: f.writer, volumeID: { f.relative($0) == "A" ? nil : "volume" })
        }
        #expect(try f.start(launch(), ["A", "B"]) == ["A", "B"])
        #expect(try f.start(launch(), ["A", "B"]) == ["A"])
    }

    @Test func rulesChangedSinceTheLastLaunchCrawlEverySource() throws {
        let f = try Fixture()
        try f.start(f.launch(), ["A", "B"])

        var rules = FileIndexRules.defaults
        rules.skipped.insert(.hidden)
        #expect(try f.start(f.launch(rules: rules), ["A", "B"]) == ["A", "B"])
        #expect(try f.start(f.launch(rules: rules), ["A", "B"]).isEmpty)
    }

    @Test func aCrawlThatNeverFinishedIsCrawledAgain() throws {
        let f = try Fixture()
        let first = f.launch()
        _ = try first.setSources([(path: f.path("A"), isEnabled: true), (path: f.path("B"), isEnabled: true)])
        try first.crawl(f.path("A"))
        // Quit before B was read.

        #expect(try f.start(f.launch(), ["A", "B"]) == ["B"])
    }

    @Test func aSourceNobodyWatchedIsCrawledWhenItComesBack() throws {
        let f = try Fixture()
        let first = f.launch()
        try f.start(first, ["A", "B"])
        try f.start(first, ["A", "B"], disabled: ["B"])

        #expect(try f.start(f.launch(), ["A", "B"], disabled: ["B"]).isEmpty)
        #expect(try f.start(f.launch(), ["A", "B"]) == ["B"], "switched off, nothing watched it")
    }

    @Test func rulesThatLetMoreInLeaveEveryRootToCrawlUntilItIsRead() throws {
        let f = try Fixture()
        let first = f.launch()
        try f.start(first, ["A", "B"])

        var open = FileIndexRules.defaults
        open.skipped.remove(.dependencies)
        #expect(try first.setRules(open).count == 2)
        try first.crawl(f.path("A"))
        // Quit before B was read under the new rules.

        #expect(try f.start(f.launch(rules: open), ["A", "B"]) == ["B"])
    }

    @Test func rulesThatOnlySkipMoreKeepEveryRootCaughtUp() throws {
        let f = try Fixture()
        let first = f.launch()
        try f.start(first, ["A"])

        var tighter = FileIndexRules.defaults
        tighter.skipped.insert(.keys)
        #expect(try first.setRules(tighter).isEmpty)

        #expect(try f.start(f.launch(rules: tighter), ["A"]).isEmpty)
    }

    // MARK: - FSEvents losing track

    @Test(arguments: [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
                      kFSEventStreamEventFlagEventIdsWrapped])
    func lostTrackCrawlsEverySource(flag: Int) throws {
        let f = try Fixture()
        let indexer = f.launch()
        try f.start(indexer, ["A", "B"])
        try f.folder.makeFile("B/missed.txt")

        try indexer.handle([Self.event("/", flag, id: 5)])

        #expect(f.crawled.count == 4)
        #expect(f.crawled.suffix(2) == ["A", "B"], "every watched root, again")
        #expect(try f.indexed.contains("B/missed.txt"))
        #expect(try f.writer.eventID() == 5, "after a wrap, the new IDs are the ones to replay from")
    }

    @Test func mustScanSubDirsAtARootIsACrawlAndBelowItIsNot() throws {
        let f = try Fixture()
        let indexer = f.launch()
        try f.start(indexer, ["A"])
        try f.folder.makeFile("A/dir/x.txt")

        try indexer.handle([Self.event(f.path("A/dir"), kFSEventStreamEventFlagMustScanSubDirs, id: 1)])
        #expect(f.crawled == ["A"], "a subtree is read again without saying Reading")
        #expect(try f.indexed.contains("A/dir/x.txt"))

        try indexer.handle([Self.event(f.path("A"), kFSEventStreamEventFlagMustScanSubDirs, id: 2)])
        #expect(f.crawled == ["A", "A"])
    }

    // MARK: - A real replay

    /// Indexes a folder, changes it with nothing watching, then starts again
    /// the way the app does — a fresh indexer and a stream from the stored
    /// event ID — and waits for the changes to land. No crawl reads them.
    @Test func whatChangedWhileNothingWatchedArrivesWithoutACrawl() async throws {
        let f = try Fixture()
        try f.folder.makeFile("A/old.txt")
        try f.start(f.launch(), ["A"])
        try f.folder.removeItem("A/old.txt")
        try f.folder.makeFile("A/while closed.txt")

        let indexer = f.launch()
        #expect(try f.start(indexer, ["A"]).isEmpty)
        let queue = DispatchQueue(label: "test.file-index-catch-up")
        let resumed = Mutex(false)
        let expected: Set<String> = ["A", "A/while closed.txt"]

        var watcher: FileIndexWatcher?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.sync {
                watcher = FileIndexWatcher(paths: indexer.watchedPaths, since: indexer.eventID, queue: queue) { events in
                    try? indexer.handle(events)
                    guard (try? f.indexed) == expected else { return }
                    let first = resumed.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    if first { continuation.resume() }
                }
            }
            #expect(watcher != nil)
        }
        queue.sync { watcher?.stop() }

        #expect(f.crawled == ["A"], "the first launch's crawl, and no other")
        #expect(try f.writer.eventID() ?? 0 > 0)
    }
}
