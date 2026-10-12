import AppKit
import os

/// One run of Finder's Target list: the File Index first, which answers at
/// once for the folder Sources, then `mdfind` over the priority folders and
/// over everything at once for the rest, ranked, then given icons. The File
/// Index's Targets come first and Spotlight's go below them, without a path
/// twice. Thumbnails are not made
/// here: each Target carries its URL, and a row asks `Thumbnails` for one only
/// once it is on screen. No UI state —
/// `TargetSearchVM` owns one of these per Query and cancels it the moment the
/// Query moves on.
///
/// Every stage is an `OSSignposter` interval under the "Search" category, so a
/// slow Target list can be read off Instruments rather than guessed at.
nonisolated final class FileTargetSearch: @unchecked Sendable {
    enum Scope: CaseIterable {
        case priorityFolders
        case systemWide

        /// How many paths a lookup reads before it stops `mdfind`. Spotlight
        /// answers `-name a` with hundreds of thousands of paths, and reading
        /// them all is most of what made this list slow. A few hundred is
        /// still several times `resultLimit`, so ranking has real candidates
        /// to choose between.
        var lineCap: Int {
            switch self {
            case .priorityFolders: 500
            case .systemWide: 300
            }
        }
    }

    /// How a lookup is launched: `mdfind` in the app, a stand-in in tests.
    typealias Launcher = @Sendable (_ query: String, _ scope: Scope) -> (executable: URL, arguments: [String])

    static let mdfind: Launcher = { query, scope in
        var arguments: [String] = []
        if scope == .priorityFolders {
            for folder in priorityFolders {
                arguments += ["-onlyin", folder]
            }
        }
        arguments += ["-name", query]
        return (URL(fileURLWithPath: "/usr/bin/mdfind"), arguments)
    }

    static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.codiclens",
        category: "Search"
    )

    static let resultLimit = 50

    static let priorityFolders: [String] = {
        let home = NSHomeDirectory()
        return [
            home + "/Downloads/",
            home + "/Documents/",
            home + "/Desktop/"
        ]
    }()

    let query: String
    private let searchFiles: FileIndex.Search
    private let launcher: Launcher

    private let lock = NSLock()
    private var processes: [Process] = []
    private var cancelled = false

    init(
        query: String,
        searchFiles: @escaping FileIndex.Search,
        launcher: @escaping Launcher = FileTargetSearch.mdfind
    ) {
        self.query = query
        self.searchFiles = searchFiles
        self.launcher = launcher
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    /// Terminates every lookup still running and stops any from starting.
    /// Safe from any thread; `run()` then returns `nil`.
    func cancel() {
        let running = lock.withLock {
            cancelled = true
            return processes
        }
        for process in running where process.isRunning {
            process.terminate()
        }
    }

    /// The whole list for `query`: the File Index's Targets, then
    /// Spotlight's — or `nil` if cancelled. `TargetSearchVM` shows the two
    /// halves as each arrives; this is what it ends up holding.
    func run() -> [ActionTarget]? {
        let indexed = indexTargets()
        guard let rest = spotlightTargets(excluding: indexed) else { return nil }
        return indexed + rest
    }

    /// The File Index's Targets for `query`, best first: files named like
    /// it, then files that say it, under their Passage. A few milliseconds,
    /// so the list has rows while Spotlight is still looking. Apps are left
    /// out, as `readPaths` leaves them out of `mdfind`'s.
    func indexTargets() -> [ActionTarget] {
        let hits = Self.signposter.withIntervalSignpost("File Index", id: Self.signposter.makeSignpostID()) {
            searchFiles(query).filter { $0.url.pathExtension != "app" }
        }
        let passages = Dictionary(hits.compactMap { hit in hit.passage.map { (hit.url.path, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        return Self.targets(for: hits.map(\.url.path), passages: passages)
    }

    /// `mdfind`'s Targets for `query`, best first, leaving out every path
    /// `indexed` already has — or `nil` if cancelled, so a stale Query never
    /// costs a single icon.
    func spotlightTargets(excluding indexed: [ActionTarget]) -> [ActionTarget]? {
        let known = Set(indexed.compactMap { $0.url?.path })
        let paths = candidatePaths().filter { !known.contains($0) }
        guard !isCancelled else { return nil }
        let ranked = Self.rank(paths, query: query)
        guard !isCancelled else { return nil }
        return Self.targets(for: ranked)
    }

    /// Every path both lookups returned, priority folders first. The two
    /// lookups run side by side.
    func candidatePaths() -> [String] {
        let group = DispatchGroup()
        // Written once on the other queue, read only after `group.wait()`.
        nonisolated(unsafe) var systemWide: [String] = []
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            systemWide = self.lookup(.systemWide)
        }
        let priority = lookup(.priorityFolders)
        group.wait()

        let prioritySet = Set(priority)
        return priority + systemWide.filter { !prioritySet.contains($0) }
    }

    /// One `mdfind`, read line by line and stopped at `scope.lineCap`.
    func lookup(_ scope: Scope) -> [String] {
        let name: StaticString = scope == .priorityFolders ? "mdfind priority" : "mdfind system-wide"
        return Self.signposter.withIntervalSignpost(name, id: Self.signposter.makeSignpostID()) {
            let (executable, arguments) = launcher(query, scope)
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            guard launch(process) else { return [] }
            let lines = Self.readPaths(from: pipe.fileHandleForReading, upTo: scope.lineCap)
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            return lines
        }
    }

    /// Starts `process` unless the search is already cancelled, and registers
    /// it so `cancel()` can reach it. A cancel that lands mid-launch finds it
    /// registered or is found here.
    private func launch(_ process: Process) -> Bool {
        guard !isCancelled else { return false }
        do {
            try process.run()
        } catch {
            return false
        }
        let cancelledMeanwhile = lock.withLock {
            processes.append(process)
            return cancelled
        }
        if cancelledMeanwhile { process.terminate() }
        return true
    }

    /// Newline-separated paths from `handle` as they arrive, until `cap` of
    /// them or end of file. Apps are left out: they are the Subject list's.
    static func readPaths(from handle: FileHandle, upTo cap: Int) -> [String] {
        var paths: [String] = []
        var pending = Data()

        func take(_ line: Data) {
            guard !line.isEmpty else { return }
            let path = String(decoding: line, as: UTF8.self)
            if !path.hasSuffix(".app") { paths.append(path) }
        }

        while paths.count < cap {
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                take(pending)
                break
            }
            pending.append(chunk)

            var lineStart = pending.startIndex
            while paths.count < cap,
                  let newline = pending[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                take(pending[lineStart..<newline])
                lineStart = pending.index(after: newline)
            }
            pending = pending[lineStart...]
        }
        return paths
    }

    /// The best `resultLimit` of `paths` for `query`: anything in a priority
    /// folder first, then by match quality. Names only — no file is touched.
    static func rank(_ paths: [String], query: String) -> [String] {
        paths
            .compactMap { path -> (path: String, priority: Int, score: Int)? in
                let name = URL(fileURLWithPath: path).lastPathComponent
                guard let score = fuzzyScore(name, query) else { return nil }
                return (path, folderPriority(for: path), score)
            }
            .sorted { ($0.priority, $0.score) < ($1.priority, $1.score) }
            .prefix(resultLimit)
            .map(\.path)
    }

    /// `rank`, then a Target with an icon for each of the survivors.
    static func targets(from paths: [String], query: String) -> [ActionTarget] {
        targets(for: rank(paths, query: query))
    }

    /// A Target per path, under its folder — or, for a file the File Index
    /// found by its words, under its Passage.
    private static func targets(for rankedPaths: [String], passages: [String: FileHit.Passage] = [:]) -> [ActionTarget] {
        let home = NSHomeDirectory()
        return signposter.withIntervalSignpost("Icons", id: signposter.makeSignpostID()) {
            rankedPaths.map { path in
                let url = URL(fileURLWithPath: path)
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: 32, height: 32)
                let passage = passages[path]
                return ActionTarget(
                    name: url.lastPathComponent,
                    icon: icon,
                    thumbnailURL: url,
                    subtitle: passage?.subtitle ?? shortenPath(path, home: home),
                    subtitleMarks: passage?.subtitleMatches,
                    url: url,
                    sharingService: nil
                )
            }
        }
    }

    private static func shortenPath(_ path: String, home: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        if dir.hasPrefix(home) {
            return "~" + dir.dropFirst(home.count)
        }
        return dir
    }

    private static func folderPriority(for path: String) -> Int {
        for folder in priorityFolders {
            if path.hasPrefix(folder) { return 0 }
        }
        return 1
    }
}
