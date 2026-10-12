import CoreServices
import Foundation

/// File-level FSEvents over the folder Sources. Reports *which* paths changed,
/// a batch at a time, and leaves deciding what that means to `FileIndexer` —
/// which looks at each path on disk rather than trusting the flags, because
/// FSEvents coalesces a create, a rename and a delete of one path into one
/// event with all three flags set.
///
/// A burst of changes arrives as one batch through FSEvents' own `latency`,
/// not a timer run on the side. Batches are delivered on the queue the
/// watcher is given, which is the indexer's: a batch can never interleave
/// with a crawl.
nonisolated final class FileIndexWatcher {
    struct Event: Equatable, Sendable {
        let path: String
        let flags: FSEventStreamEventFlags

        init(path: String, flags: FSEventStreamEventFlags = 0) {
            self.path = path
            self.flags = flags
        }

        /// FSEvents lost track below `path` — it dropped events, or merged
        /// them past telling apart — and the subtree has to be read again.
        var mustRescan: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped) != 0
        }

        /// Events were dropped wholesale: nothing below any root can be trusted.
        var droppedEvents: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped) != 0
        }

        /// A watched root itself was moved, deleted or created.
        var rootChanged: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
        }

        /// Bookkeeping, not a change to anything on disk.
        var isBookkeeping: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone
                | kFSEventStreamEventFlagEventIdsWrapped) != 0
        }
    }

    /// The coalescing window, in seconds. Short, because a download should be
    /// findable by the time the user goes looking for it; long enough that an
    /// unzip or a copy of a folder arrives as one batch.
    static let latency: CFTimeInterval = 0.5

    private let handler: ([Event]) -> Void
    private var stream: FSEventStreamRef?

    /// Starts watching `paths` straight away, delivering on `queue`.
    ///
    /// `since` is where a replacement stream picks up from: restarting with a
    /// changed set of folders passes the old stream's `latestEventID`, so no
    /// change in a folder watched by both is lost in between.
    init?(
        paths: [String],
        since: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        queue: DispatchQueue,
        handler: @escaping ([Event]) -> Void
    ) {
        self.handler = handler
        guard !paths.isEmpty else { return nil }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileIndexWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let events = (0..<min(count, list.count)).map { Event(path: list[$0], flags: flags[$0]) }
            watcher.handler(events)
        }

        // `WatchRoot` reports a root that is moved or deleted; `FileEvents`
        // names the file that changed rather than only its folder.
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            since,
            Self.latency,
            flags
        ) else { return nil }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        stop()
    }

    /// The last event this stream has seen, for a replacement to start after.
    var latestEventID: FSEventStreamEventId {
        stream.map(FSEventStreamGetLatestEventId) ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    }

    /// Stops watching and releases the stream. A second call does nothing.
    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
