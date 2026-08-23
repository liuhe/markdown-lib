import Foundation
import CoreServices

/// Recursive filesystem watcher backed by `FSEventStream`. Coalesces bursts
/// (a batch fires after the FSEvents latency + a debounce tail). Passes the
/// unique changed paths from the batch to `onChange` so the caller can decide
/// whether the changes are worth reacting to (e.g., filter out events under
/// `node_modules`, `.git`, `bazel-*`).
final class FileTreeWatcher {

    /// Fires on the main queue with the deduped set of paths that changed
    /// during the debounce window.
    var onChange: ([String]) -> Void

    private var stream: FSEventStreamRef?
    private let debounceQueue = DispatchQueue.main
    private var pending: DispatchWorkItem?

    /// Accumulate paths across FSEvent bursts until the debounce fires.
    private var pendingPaths: Set<String> = []

    /// FSEventStream latency in seconds. Small enough that renames feel
    /// instant but big enough to coalesce a git-checkout or bulk rename.
    private let latency: CFTimeInterval = 0.2

    init(url: URL, onChange: @escaping ([String]) -> Void) {
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

        let callback: FSEventStreamCallback = { _, info, count, pathsPtr, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileTreeWatcher>.fromOpaque(info).takeUnretainedValue()
            // eventPaths is documented as an NSArray of NSString when the
            // stream was created without kFSEventStreamCreateFlagUseCFTypes —
            // which is the default. Bridge to Swift.
            let ns = unsafeBitCast(pathsPtr, to: NSArray.self)
            var changed: [String] = []
            changed.reserveCapacity(count)
            for i in 0..<count {
                if let s = ns[i] as? String { changed.append(s) }
            }
            watcher.trigger(paths: changed)
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
        pendingPaths.removeAll()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func trigger(paths: [String]) {
        pendingPaths.formUnion(paths)
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = Array(self.pendingPaths)
            self.pendingPaths.removeAll(keepingCapacity: true)
            self.onChange(batch)
        }
        pending = work
        // 500 ms of quiet on top of FSEvents' own 200 ms latency before we
        // decide a burst is done. Chosen to collapse the tail of a git
        // checkout / bazel build without noticeably delaying reaction to a
        // one-off save.
        debounceQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
