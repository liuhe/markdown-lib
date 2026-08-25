import Foundation

/// Lightweight performance-logging + main-thread stall detector, both wired
/// to stderr with visible markers so hiccups jump out in Console.app or a
/// terminal-launched run.
///
/// Two independent signals:
///   ⚠️ [slow] label: N ms      — a `measure { ... }` block exceeded the
///                                slow-block threshold.
///   🚨 [main-stall] N ms       — the main runloop went that long without
///                                servicing its heartbeat; includes the
///                                last activity marker for context.
///
/// Enabled by default. Disable at launch with `MDLIB_PERF=0`.
public enum PerfLog {

    /// Blocks that take longer than this print a ⚠️ line to stderr.
    public static var slowBlockThreshold: TimeInterval = 0.050
    /// Main-thread gaps longer than this print a 🚨 line.
    public static var mainStallThreshold: TimeInterval = 0.150

    public static let enabled: Bool = {
        ProcessInfo.processInfo.environment["MDLIB_PERF"] != "0"
    }()

    /// Called once from `MainThreadStallMonitor.start()`. Kills any stdio
    /// buffering on `stderr` so log bursts you see in the terminal reflect
    /// real event bursts, not a batched flush.
    public static func configureStdio() {
        setvbuf(stderr, nil, _IONBF, 0)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: - Measure

    @discardableResult
    @inline(__always)
    public static func measure<T>(_ label: @autoclosure () -> String, _ block: () throws -> T) rethrows -> T {
        guard enabled else { return try block() }
        let name = label()
        MainThreadStallMonitor.shared.markActivity(name)
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            if elapsed > slowBlockThreshold {
                write("⚠️ [slow] \(name): \(ms(elapsed)) ms")
            }
        }
        return try block()
    }

    /// Non-timing activity marker — records "this is what we're doing" so
    /// stall reports can name the last thing that was running on main.
    @inline(__always)
    public static func mark(_ label: @autoclosure () -> String) {
        guard enabled else { return }
        MainThreadStallMonitor.shared.markActivity(label())
    }

    // MARK: - Write

    public static func write(_ line: String) {
        let ts = timeFormatter.string(from: Date())
        fputs("[mdlib \(ts)] \(line)\n", stderr)
    }

    public static func ms(_ t: TimeInterval) -> String {
        String(format: "%.0f", t * 1000)
    }
}

/// Watchdog that measures main-thread responsiveness by dispatching a probe
/// block from a background queue and timing how long it sits in the queue
/// before running. Zero main-thread wake-ups when the app is idle — the only
/// cost is a `DispatchSemaphore.wait` on our own utility thread.
public final class MainThreadStallMonitor {

    public static let shared = MainThreadStallMonitor()

    private let lock = NSLock()
    private var lastActivity = "idle"
    private var running = false

    private let watchQueue = DispatchQueue(label: "mdlib.mainstall", qos: .utility)

    /// How often the probe runs when main is responsive.
    private let probeInterval: TimeInterval = 0.2

    public func markActivity(_ activity: String) {
        lock.lock()
        lastActivity = activity
        lock.unlock()
    }

    public func start() {
        guard PerfLog.enabled else { return }
        guard !running else { return }
        running = true
        PerfLog.configureStdio()

        watchQueue.async { [weak self] in
            guard let self else { return }
            var lastReportedAt = CFAbsoluteTimeGetCurrent() - 1
            while self.running {
                let dispatchedAt = CFAbsoluteTimeGetCurrent()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                // Cap the wait so a truly wedged main doesn't strand us
                // forever; we still report the wait we saw.
                _ = sem.wait(timeout: .now() + .seconds(3))
                let elapsed = CFAbsoluteTimeGetCurrent() - dispatchedAt
                if elapsed > PerfLog.mainStallThreshold,
                   CFAbsoluteTimeGetCurrent() - lastReportedAt > 0.2 {
                    self.lock.lock()
                    let activity = self.lastActivity
                    self.lock.unlock()
                    PerfLog.write("🚨 [main-stall] \(PerfLog.ms(elapsed)) ms — last activity: \(activity)")
                    lastReportedAt = CFAbsoluteTimeGetCurrent()
                }
                Thread.sleep(forTimeInterval: self.probeInterval)
            }
        }
    }
}
