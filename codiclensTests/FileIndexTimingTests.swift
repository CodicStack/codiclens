import Foundation
import Synchronization
import Testing
@testable import codiclens

private let timingRuns = ProcessInfo.processInfo.environment["CODICLENS_TIME_FILE_INDEX"].flatMap { Int($0) }

/// The rules a measurement runs under: the defaults, or with
/// `TEST_RUNNER_CODICLENS_TIME_WITHOUT_GIT_IGNORED=1` the defaults with
/// "Ignored by git" off, to see what the switch is worth. Both timing suites
/// read it.
let timingRules: FileIndexRules = {
    var rules = FileIndexRules.defaults
    if ProcessInfo.processInfo.environment["CODICLENS_TIME_WITHOUT_GIT_IGNORED"] == "1" {
        rules.skipped.remove(.gitIgnored)
    }
    return rules
}()

/// The File Index over this Mac's real Downloads, Documents and Desktop under
/// the default skip rules (`timingRules`): how long the first crawl takes, how
/// big the database comes out and what fills it, how long a launch takes to
/// catch up by FSEvents replay, what switching Repos and "Ignored by git" off
/// and on again costs, and how long a search takes. Not a pass/fail test — the numbers depend on what is
/// on disk — so it is off unless asked for. The crawl only reads the three
/// folders; the database goes to a temporary folder, never Application
/// Support.
///
/// ```
/// TEST_RUNNER_CODICLENS_TIME_FILE_INDEX=20 xcodebuild test \
///   -project codiclens.xcodeproj -scheme codiclens -configuration Debug \
///   -only-testing:codiclensTests/FileIndexTimingTests
/// ```
///
/// The variable's value is the number of runs per Query; each is their median.
@Suite(.serialized, .enabled(if: timingRuns != nil), .timeLimit(.minutes(15)))
struct FileIndexTimingTests {
    static let queries = ["invoice", "skat", "png", "a", "screenshot"]

    @Test func crawlAndQueryTimings() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        // In a function of its own, so every connection is closed by the time
        // the folder is deleted.
        try await Self.measure(url: folder.url.appendingPathComponent("FileIndex.sqlite"), runs: timingRuns ?? 1)
    }

    private static func measure(url: URL, runs: Int) async throws {
        let writer = try FileIndexWriter(url: url)
        let indexer = FileIndexer(writer: writer, rules: timingRules)
        let roots = SourceStore.defaultFolders.map { FileIndexer.realPath($0) }
        print("rules: \(timingRules.skipped.map(\.rawValue).sorted().joined(separator: ", "))")

        let crawl = ContinuousClock().measure {
            let toCrawl = (try? indexer.setSources(roots.map { (path: $0, isEnabled: true) })) ?? []
            for root in toCrawl { try? indexer.crawl(root) }
        }
        try writer.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")

        let reader = FileIndexReader(url: url)
        let counts = reader.counts().mapValues(\.total)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("crawl \(Self.ms([crawl])), \(counts.values.reduce(0, +)) rows, \(size / 1024) KB")
        for root in roots { print("  \(root): \(counts[root] ?? 0)") }

        // A launch: replaying what changed since the crawl began, then again
        // straight after, when nothing has.
        for label in ["launch catch-up after the crawl", "launch catch-up, nothing changed"] {
            let (time, events, crawled) = try await Self.catchUp(writer: writer, roots: roots)
            print("\(label): \(Self.ms([time])), \(events) events replayed, \(crawled) roots crawled")
        }

        // A second crawl over an unchanged disk: what every launch paid before
        // the replay, and still what a launch pays for a root it cannot replay.
        let recrawl = ContinuousClock().measure {
            for root in roots { try? indexer.crawl(root) }
        }
        print("re-crawl, nothing changed: \(Self.ms([recrawl]))")

        try Self.printLargest(writer: writer)

        // The Repos switch, the biggest one under the defaults, and "Ignored
        // by git": each one way and back.
        for group in [FileIndexRules.SkipGroup.repos, .gitIgnored] {
            var toggled = timingRules
            if toggled.skips(group) { toggled.skipped.remove(group) } else { toggled.skipped.insert(group) }
            var previous = timingRules
            for rules in [toggled, timingRules] {
                let how = rules.skipsAtLeast(previous) ? "prune" : "crawl"
                let time = ContinuousClock().measure {
                    for root in (try? indexer.setRules(rules)) ?? [] { try? indexer.crawl(root) }
                }
                print("\(group.rawValue) \(rules.skips(group) ? "on" : "off") (\(how)): \(Self.ms([time])), "
                      + "\(reader.counts().values.map(\.total).reduce(0, +)) rows")
                previous = rules
            }
        }

        print("query       hits        first search  median")
        for query in Self.queries {
            let cold = FileIndexReader(url: url)
            var hits: [FileHit] = []
            let first = ContinuousClock().measure { hits = cold.search(query, limit: 50, sources: roots) }
            var samples: [Duration] = []
            for _ in 0..<runs {
                samples.append(ContinuousClock().measure { hits = reader.search(query, limit: 50, sources: roots) })
            }
            print([
                query.padding(toLength: 12, withPad: " ", startingAt: 0),
                "\(hits.count)".padding(toLength: 12, withPad: " ", startingAt: 0),
                Self.ms([first]).padding(toLength: 14, withPad: " ", startingAt: 0),
                Self.ms(samples)
            ].joined())
            for hit in hits.prefix(3) { print("    \(hit.score)  \(hit.name)  (\(hit.folder))") }
        }
    }

    /// A launch over the index as it stands: a fresh indexer, a stream from
    /// the stored event ID, and the time until FSEvents says the replay is
    /// over and every batch before that has been applied.
    private static func catchUp(writer: FileIndexWriter, roots: [String]) async throws -> (Duration, Int, Int) {
        let start = ContinuousClock.now
        let queue = DispatchQueue(label: "timing.file-index-catch-up")
        let crawled = Mutex(0)
        let replayed = Mutex(0)
        let finished = Mutex(false)
        let indexer = FileIndexer(writer: writer, rules: timingRules, onProgress: { progress in
            if case .reading(_, true) = progress { crawled.withLock { $0 += 1 } }
        })
        var watcher: FileIndexWatcher?
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.sync {
                do {
                    let toCrawl = try indexer.setSources(roots.map { (path: $0, isEnabled: true) })
                    watcher = FileIndexWatcher(paths: indexer.watchedPaths, since: indexer.eventID, queue: queue) { events in
                        try? indexer.handle(events)
                        replayed.withLock { $0 += events.filter { !$0.historyDone }.count }
                        guard events.contains(where: \.historyDone) else { return }
                        let first = finished.withLock { done in
                            defer { done = true }
                            return !done
                        }
                        if first { continuation.resume() }
                    }
                    for root in toCrawl { try indexer.crawl(root) }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let elapsed = ContinuousClock.now - start
        queue.sync { watcher?.stop() }
        return (elapsed, replayed.withLock { $0 }, crawled.withLock { $0 })
    }

    /// The folders holding the most rows: the top level of each Source, the
    /// level below, and folder names wherever they are, so something huge and
    /// junky stands out whichever depth it is at.
    private static func printLargest(writer: FileIndexWriter) throws {
        var byTop: [String: Int] = [:]
        var bySecond: [String: Int] = [:]
        var byName: [String: Int] = [:]
        try writer.db.query("SELECT path, source FROM files") { row in
            let path = row.text(0) ?? "", source = row.text(1) ?? ""
            let relative = path.dropFirst(source.count).split(separator: "/").dropLast()
            let home = (source as NSString).abbreviatingWithTildeInPath
            if let first = relative.first { byTop[home + "/" + first, default: 0] += 1 }
            if relative.count >= 2 { bySecond[home + "/" + relative.prefix(2).joined(separator: "/"), default: 0] += 1 }
            for name in Set(relative) { byName[String(name), default: 0] += 1 }
        }
        for (title, counts) in [("top-level folders", byTop), ("second-level folders", bySecond),
                                ("folder names, anywhere", byName)] {
            print("largest \(title):")
            for (name, count) in counts.sorted(by: { $0.value > $1.value }).prefix(15) {
                print("  \(String(count).padding(toLength: 8, withPad: " ", startingAt: 0)) \(name)")
            }
        }
    }

    private static func ms(_ samples: [Duration]) -> String {
        let median = samples.sorted()[samples.count / 2]
        let millis = Double(median.components.seconds) * 1000
            + Double(median.components.attoseconds) / 1e15
        return String(format: "%.1f ms", millis)
    }
}
