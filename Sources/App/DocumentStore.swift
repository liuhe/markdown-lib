import Foundation
import Combine

/// Per-window document state. Owns the markdown text, the on-disk URL, the
/// last-saved snapshot for dirty-tracking, and a 2-second polling timer that
/// notices external edits.
final class DocumentStore: ObservableObject {

    @Published var text: String = ""
    @Published private(set) var fileURL: URL? = nil
    @Published private(set) var externallyModified: Bool = false

    /// Snapshot of the text last read from / written to disk. Anything else
    /// counts as an unsaved edit.
    private(set) var lastSavedText: String = ""

    /// Modification date of the file as of the last read/write. Used to detect
    /// external edits without re-reading the whole file.
    private var lastKnownModDate: Date?

    /// Wall-clock time of our most recent write. Guards against atomic-write
    /// filesystems where the mtime we read back after saving is slightly newer
    /// than the one we tracked, or where a rename bumps mtime twice — those
    /// look like an external edit on the next poll.
    private var lastSelfWriteTime: Date?
    private let selfWriteThreshold: TimeInterval = 0.5

    private var pollTimer: Timer?

    var isDirty: Bool { text != lastSavedText }

    var displayName: String {
        fileURL?.lastPathComponent ?? "Untitled"
    }

    // MARK: - Disk I/O

    func read(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let s = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        text = s
        lastSavedText = s
        fileURL = url
        lastKnownModDate = modificationDate(of: url)
        externallyModified = false
        startPolling()
    }

    /// Reloads from `fileURL`, discarding any in-memory changes.
    func revertFromDisk() {
        guard let url = fileURL else { return }
        do { try read(from: url) } catch { /* ignore */ }
    }

    func write(to url: URL) throws {
        // Suspend the timer so our own write doesn't look like an external edit.
        stopPolling()
        try Data(text.utf8).write(to: url, options: .atomic)
        lastSavedText = text
        fileURL = url
        lastKnownModDate = modificationDate(of: url)
        lastSelfWriteTime = Date()
        externallyModified = false
        startPolling()
    }

    func save() throws {
        guard let url = fileURL else { return }
        try write(to: url)
    }

    // MARK: - External-change polling

    private func startPolling() {
        stopPolling()
        guard fileURL != nil else { return }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkExternalModification()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func checkExternalModification() {
        guard let url = fileURL, let previous = lastKnownModDate else { return }
        guard let current = modificationDate(of: url) else {
            // File was deleted or moved. Surface it as an external change.
            if !externallyModified { externallyModified = true }
            return
        }
        guard current > previous else { return }
        // Debounce: ignore mtime bumps that happen within 0.5s of our own save.
        if let selfWrite = lastSelfWriteTime,
           Date().timeIntervalSince(selfWrite) < selfWriteThreshold {
            lastKnownModDate = current
            return
        }
        lastKnownModDate = current
        externallyModified = true
    }

    /// Acknowledge the external change without reloading — clears the flag.
    func dismissExternalModification() {
        externallyModified = false
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    deinit { stopPolling() }
}
