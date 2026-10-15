import CoreServices
import Foundation

/// Streams file-system changes under the roots using FSEvents. Changes are batched, and the
/// last event ID is handed back so a restart can replay what happened while Trail wasn't running.
public final class Watcher: @unchecked Sendable {
    public struct Batch: Sendable {
        public var paths: Set<String>
        /// Folders that appeared or were moved in; their contents need a walk.
        public var rescan: Set<String>
        public var lastEventID: UInt64
    }

    private let roots: [String]
    private let since: FSEventStreamEventId
    private let queue = DispatchQueue(label: "trail.watcher", qos: .utility)
    private let handler: @Sendable (Batch) -> Void
    private var stream: FSEventStreamRef?
    private var pending = Batch(paths: [], rescan: [], lastEventID: 0)
    private var flushScheduled = false

    public init(roots: [String], since eventID: UInt64?, handler: @escaping @Sendable (Batch) -> Void) {
        self.roots = roots
        self.since = eventID ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        self.handler = handler
    }

    public static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    public func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.receive(paths: paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)),
                            ids: Array(UnsafeBufferPointer(start: ids, count: count)))
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray, since, 2.0, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private func receive(paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
        for (index, path) in paths.enumerated() {
            let flag = Int(flags[index])
            if flag & kFSEventStreamEventFlagHistoryDone != 0 { continue }
            let isDirectory = flag & kFSEventStreamEventFlagItemIsDir != 0
            let created = flag & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
            if flag & kFSEventStreamEventFlagMustScanSubDirs != 0 || (isDirectory && created) {
                pending.rescan.insert(path)
            }
            pending.paths.insert(path)
            pending.lastEventID = max(pending.lastEventID, ids[index])
        }
        // Wait a moment so a burst of saves becomes one batch.
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let batch = self.pending
            self.pending = Batch(paths: [], rescan: [], lastEventID: batch.lastEventID)
            self.flushScheduled = false
            self.handler(batch)
        }
    }
}
