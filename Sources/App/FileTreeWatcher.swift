import Foundation
import CoreServices

/// Recursive filesystem watcher backed by `FSEventStream`. Coalesces bursts
/// (the initial event fires immediately after ~150 ms; subsequent events in
/// the same burst are dropped in favor of the last one).
final class FileTreeWatcher {

    /// Called on the main queue after debouncing. Fire-and-forget: the
    /// callback receives no diff, since we always regenerate the tree.
    var onChange: () -> Void

    private var stream: FSEventStreamRef?
    private let debounceQueue = DispatchQueue.main
    private var pending: DispatchWorkItem?

    /// FSEventStream latency in seconds. Small enough that renames feel
    /// instant but big enough to coalesce a git-checkout or bulk rename.
    private let latency: CFTimeInterval = 0.2

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        start(url: url)
    }

    deinit { stop() }

    // MARK: - Start / stop

    private func start(url: URL) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [url.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagIgnoreSelf
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileTreeWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.trigger()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, debounceQueue)
        FSEventStreamStart(stream)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func trigger() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        // Extra 100 ms on top of FSEvents' own latency so we collapse the tail
        // of a burst (e.g., editor writes tmp → rename → touch).
        debounceQueue.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}
