import Foundation
import Combine

/// Per-window document state. Owns the markdown text, the on-disk URL, the
/// last-saved snapshot for dirty-tracking, and a 2-second polling timer that
/// notices external edits.
///
/// `text` is the **body** of the document — YAML frontmatter (if any) is
/// stripped on read and stored separately in `rawFrontmatter` so it survives
/// a save without the app having to understand its schema. Only known keys
/// (currently just `title`) are surfaced as computed properties.
final class DocumentStore: ObservableObject {

    @Published var text: String = ""
    @Published private(set) var fileURL: URL? = nil
    @Published private(set) var externallyModified: Bool = false

    /// Raw YAML content between the leading `---` and closing `---`, exactly
    /// as it was on disk. `nil` when the file has no frontmatter block.
    /// Reassembled verbatim on save.
    @Published private(set) var rawFrontmatter: String? = nil

    /// Flipped whenever `setFrontmatter(_:)` mutates `rawFrontmatter` without
    /// a corresponding save. `write(to:)` and `read(from:)` clear it.
    @Published private(set) var frontmatterDirty: Bool = false

    /// Snapshot of the *body* last read from / written to disk. Frontmatter
    /// changes go through `frontmatterDirty` because their diff isn't visible
    /// to the body-vs-lastSavedText comparison.
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

    var isDirty: Bool { text != lastSavedText || frontmatterDirty }

    /// Programmatically replace the raw YAML frontmatter block. Empty strings
    /// are treated as "no frontmatter". Sets `frontmatterDirty` when the new
    /// value differs from the current one so the tab title picks up the
    /// "— Edited" suffix and the close-window prompt fires.
    func setFrontmatter(_ value: String?) {
        let normalized: String? = (value?.isEmpty == true) ? nil : value
        guard normalized != rawFrontmatter else { return }
        rawFrontmatter = normalized
        frontmatterDirty = true
    }

    /// Value of the `title:` key from the frontmatter, or nil if none.
    var title: String? {
        guard let fm = rawFrontmatter else { return nil }
        return Frontmatter.title(in: fm)
    }

    /// Prefer the frontmatter title, then the filename, then "Untitled".
    /// Drives tab labels + window title.
    var displayName: String {
        if let t = title, !t.isEmpty { return t }
        return fileURL?.lastPathComponent ?? "Untitled"
    }

    // MARK: - Disk I/O

    func read(from url: URL) throws {
        try PerfLog.measure("DocumentStore.read(\(url.lastPathComponent))") {
            let data = try Data(contentsOf: url)
            guard let s = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            let (fm, body) = Frontmatter.split(s)
            rawFrontmatter = fm
            text = body
            lastSavedText = body
            frontmatterDirty = false
            fileURL = url
            lastKnownModDate = modificationDate(of: url)
            externallyModified = false
            startPolling()
        }
    }

    /// Reloads from `fileURL`, discarding any in-memory changes.
    func revertFromDisk() {
        guard let url = fileURL else { return }
        do { try read(from: url) } catch { /* ignore */ }
    }

    func write(to url: URL) throws {
        try PerfLog.measure("DocumentStore.write(\(url.lastPathComponent))") {
            // Suspend the timer so our own write doesn't look like an external edit.
            stopPolling()
            let full = Frontmatter.assemble(frontmatter: rawFrontmatter, body: text)
            try Data(full.utf8).write(to: url, options: .atomic)
            lastSavedText = text
            frontmatterDirty = false
            fileURL = url
            lastKnownModDate = modificationDate(of: url)
            lastSelfWriteTime = Date()
            externallyModified = false
            startPolling()
        }
    }

    func save() throws {
        guard let url = fileURL else { return }
        try write(to: url)
    }

    /// Point the store at a new URL without re-reading — used after an
    /// external rename that we performed ourselves via `WorkspaceStore`.
    /// Disk contents didn't change, so `text` / `lastSavedText` stay put; we
    /// just re-baseline the modification date.
    func retarget(to url: URL) {
        stopPolling()
        fileURL = url
        lastKnownModDate = modificationDate(of: url)
        lastSelfWriteTime = Date()
        externallyModified = false
        startPolling()
    }

    /// Called when the on-disk file backing this store has been deleted. We
    /// clear the URL so the store looks "untitled", which forces a Save As
    /// on the next save. Dirty state is preserved.
    func detachFromDisk() {
        stopPolling()
        fileURL = nil
        lastKnownModDate = nil
        lastSelfWriteTime = nil
        externallyModified = false
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
