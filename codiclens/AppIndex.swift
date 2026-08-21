import AppKit

/// One installed app as the Index records it: enough to match it, show it, and
/// launch it — and deliberately no icon. Icons cost an `NSWorkspace` lookup
/// each, and a rebuild would pay that toll for a couple of hundred apps the
/// user will never see. `AppIndex.subject(for:)` resolves one when a match
/// actually reaches the screen.
struct IndexedApp: Sendable, Equatable {
    let displayName: String
    let path: String
    let bundleIdentifier: String?

    var url: URL { URL(fileURLWithPath: path) }
}

/// The Index: the in-memory list of installed apps that Subject search matches
/// against.
///
/// Rebuilt in full whenever FSEvents says the application directories changed,
/// and on demand via `refresh()`. Never merged into — an app that was
/// uninstalled has to disappear from search, or Enter launches a path that
/// isn't there any more.
///
/// Built-ins are not in here. They aren't files on disk, they can't be
/// scanned for, and a rebuild must not be able to drop them; `SubjectSearchVM`
/// owns them and matches them alongside the Index.
@Observable
final class AppIndex {
    /// The app's Index.
    static let shared = AppIndex()

    /// The five directories the Index is built from.
    static let searchDirectories: [String] = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices",
        NSHomeDirectory() + "/Applications"
    ]

    /// The Index itself. Only ever replaced wholesale, in one assignment.
    private(set) var apps: [IndexedApp] = []

    /// Bumped on every swap, so an observer can tell one Index from the next
    /// without diffing the array.
    private(set) var generation: Int = 0

    /// True while a rebuild is in flight. Settings can show a spinner off this.
    private(set) var isRefreshing: Bool = false

    /// True once a scan has come back with at least one app. Distinguishes
    /// "the Index is empty because nothing is installed" from "the first scan
    /// hasn't landed yet", which are different states for search.
    private(set) var hasPopulated: Bool = false

    /// The directories this Index scans and watches. An Index over none of
    /// them never scans and never watches, which is what tests want.
    private let directories: [String]

    private var watcher: AppDirectoryWatcher?
    private var rebuildRequested = false
    private var iconCache: [String: NSImage] = [:]
    private var firstPopulationHandlers: [() -> Void] = []

    init(directories: [String] = AppIndex.searchDirectories) {
        self.directories = directories
    }

    /// Kicks off the first scan and starts watching. Safe to call repeatedly;
    /// only the first call does anything.
    ///
    /// The first scan runs on a background queue like every other one, so a
    /// cold start never blocks the main thread on ~200 bundle reads.
    func start() {
        guard watcher == nil else { return }

        let watcher = AppDirectoryWatcher(paths: directories) { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
        self.watcher = watcher
        watcher.start()

        refresh()
    }

    /// Stops watching the application directories.
    ///
    /// Called from `applicationWillTerminate`. `AppIndex.shared` is a singleton
    /// and never deinitialises, so the FSEvents stream it holds would otherwise
    /// outlive the app's decision to quit. A rebuild already in flight is left
    /// to finish and land on a dead Index — harmless, and cheaper than a
    /// cancellation protocol nothing else needs.
    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Rebuilds the Index from disk.
    ///
    /// This is the entry point for a manual refresh — `AppIndex.shared.refresh()`
    /// from anywhere, including a Settings button. Cheap to call: a rebuild
    /// already running collapses repeat calls into one follow-up scan.
    func refresh() {
        guard !isRefreshing else {
            rebuildRequested = true
            return
        }
        isRefreshing = true

        let directories = self.directories
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scanned = AppIndex.scan(directories)
            DispatchQueue.main.async { [weak self] in
                self?.adopt(scanned)
            }
        }
    }

    /// The swap. One assignment to `apps`, so no reader ever sees a half-built
    /// Index, and nothing here touches results already on screen — see
    /// `SubjectSearchVM.updateResults`.
    private func adopt(_ scanned: [IndexedApp]) {
        apps = scanned
        generation &+= 1
        isRefreshing = false

        let live = Set(scanned.map(\.path))
        iconCache = iconCache.filter { live.contains($0.key) }

        if !hasPopulated, !scanned.isEmpty {
            hasPopulated = true
            let handlers = firstPopulationHandlers
            firstPopulationHandlers = []
            for handler in handlers { handler() }
        }

        if rebuildRequested {
            rebuildRequested = false
            refresh()
        }
    }

    /// Calls `handler` once, when the Index first goes from empty to populated
    /// — or straight away, if that already happened. Never fires for a later
    /// rebuild: those are the ones search deliberately ignores mid-query.
    func onFirstPopulation(_ handler: @escaping () -> Void) {
        guard !hasPopulated else {
            handler()
            return
        }
        firstPopulationHandlers.append(handler)
    }

    /// Turns an indexed app into a Subject, resolving its icon now.
    ///
    /// `Subject.icon` is non-optional, so this is where the scan's laziness
    /// ends. Only the handful of matches that reach the UI ever cost a lookup,
    /// and the cache keeps a re-typed query from paying twice.
    func subject(for app: IndexedApp) -> Subject {
        Subject(
            displayName: app.displayName,
            path: app.path,
            url: app.url,
            icon: icon(forPath: app.path),
            kind: .app(bundleIdentifier: app.bundleIdentifier, isRunning: false)
        )
    }

    private func icon(forPath path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        iconCache[path] = icon
        return icon
    }

    // MARK: - Scanning

    /// A full recursive walk of the application directories. Runs off the main
    /// thread; touches nothing but the filesystem.
    nonisolated private static func scan(_ directories: [String]) -> [IndexedApp] {
        let fm = FileManager.default
        var apps: [IndexedApp] = []
        var seen = Set<String>()

        for directory in directories {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else { continue }
                enumerator.skipDescendants()

                let path = url.path
                guard seen.insert(path).inserted else { continue }

                apps.append(IndexedApp(
                    displayName: url.deletingPathExtension().lastPathComponent,
                    path: path,
                    bundleIdentifier: Bundle(path: path)?.bundleIdentifier
                ))
            }
        }

        return apps
    }
}
