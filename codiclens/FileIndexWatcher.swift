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
///
/// A stream always starts from an event ID, never "now": at launch the one
/// the index was left at, so FSEvents first replays what changed while the
/// app was not running, then says `historyDone`, then carries on live.
nonisolated final class FileIndexWatcher {
    struct Event: Equatable, Sendable {
        let path: String
        let flags: FSEventStreamEventFlags
        /// FSEvents' own number for the change, which the index stores as
        /// how far it has caught up. Nil only in a test's hand-made batch.
        let id: FSEventStreamEventId?

        init(path: String, flags: FSEventStreamEventFlags = 0, id: FSEventStreamEventId? = nil) {
            self.path = path
            self.flags = flags
            self.id = id
        }

        /// FSEvents lost track below `path` — it dropped events, or merged
        /// them past telling apart — and the subtree has to be read again.
        var mustRescan: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped) != 0
        }

        /// Events were dropped wholesale, or event IDs started again from
        /// zero: nothing below any root can be trusted.
        var lostTrack: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped) != 0
        }

        /// A watched root itself was moved, deleted or created.
        var rootChanged: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
        }

        /// The end of the replay a stream started from an old event ID: what
        /// follows is live. Not a change to anything on disk, and its ID is
        /// not one.
        var historyDone: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0
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
    /// `since` is the last event already accounted for; everything after it
    /// is delivered, history first. At launch it is the index's stored event
    /// ID. Restarting with a changed set of folders passes the old stream's
    /// `latestEventID`, so no change in a folder watched by both is lost in
    /// between.
    init?(
        paths: [String],
        since: FSEventStreamEventId = FSEventsGetCurrentEventId(),
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

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<FileIndexWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let events = (0..<min(count, list.count)).map { Event(path: list[$0], flags: flags[$0], id: ids[$0]) }
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

    /// The last event this stream has seen — or, before any, the one it
    /// started from — for a replacement to start after.
    var latestEventID: FSEventStreamEventId {
        stream.map(FSEventStreamGetLatestEventId) ?? FSEventsGetCurrentEventId()
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
