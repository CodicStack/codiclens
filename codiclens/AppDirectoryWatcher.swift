import CoreServices
import Foundation

/// Watches the application directories and reports that something under one of
/// them changed. It says *that* something changed, never *what* — the Index is
/// rebuilt in full either way.
///
/// A burst of writes — an installer unpacking a bundle — arrives as one report.
/// The coalescing is FSEvents' own `latency` parameter, which is part of the
/// API's contract, not a timer we run on the side.
nonisolated final class AppDirectoryWatcher {
    /// The FSEvents coalescing window, in seconds. Long enough to swallow an
    /// install, short enough that a new app is searchable before the user goes
    /// looking for it.
    static let latency: CFTimeInterval = 1.0

    private let paths: [String]
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.codiclens.app-directory-watcher", qos: .utility)
    private var stream: FSEventStreamRef?

    init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// Starts watching. A second call does nothing.
    func start() {
        guard stream == nil else { return }
        guard let stream = makeStream(for: paths) ?? makeStream(for: paths.filter(Self.directoryExists)) else {
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func makeStream(for paths: [String]) -> FSEventStreamRef? {
        guard !paths.isEmpty else { return nil }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<AppDirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }

        // `WatchRoot` is what keeps a directory that doesn't exist yet — `~/Applications`
        // usually doesn't — from being a dead entry: creating it later is itself an event.
        let flags = UInt32(kFSEventStreamCreateFlagWatchRoot)

        return FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags
        )
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
