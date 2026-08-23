import Foundation
import AppKit
import Combine

/// One node in the workspace file tree. Directories carry a non-nil `children`
/// (possibly empty); files carry `nil` so SwiftUI's `OutlineGroup` treats them
/// as leaves.
struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let children: [FileNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// One open folder. Owns the recursively scanned file tree, plus an FSEvents
/// watcher that refreshes it on any change under the root. Also exposes the
/// filesystem operations exercised by the sidebar context menu.
final class WorkspaceStore: ObservableObject {

    @Published private(set) var rootURL: URL
    @Published private(set) var root: FileNode

    private var watcher: FileTreeWatcher?

    /// File extensions we consider "editable" — used by the sidebar to grey
    /// out or hide obvious non-text files.
    static let editableExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt", "text", "rst",
    ]

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.root = Self.scan(url: rootURL)
        startWatching()
    }

    deinit { watcher?.stop() }

    func refresh() {
        root = Self.scan(url: rootURL)
    }

    static func isEditable(_ url: URL) -> Bool {
        editableExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Watching

    private func startWatching() {
        watcher = FileTreeWatcher(url: rootURL) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Filesystem ops
    //
    // Each op mutates the disk, then triggers refresh(). (The FSEvents
    // watcher will also fire, but calling refresh() eagerly means the sidebar
    // updates in the same run loop tick as the user's action.)

    enum FSError: LocalizedError {
        case invalidName
        case exists(URL)
        case notInWorkspace
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .invalidName: return "Invalid file name."
            case .exists(let url): return "“\(url.lastPathComponent)” already exists."
            case .notInWorkspace: return "That path is outside the workspace."
            case .underlying(let err): return err.localizedDescription
            }
        }
    }

    /// Create an empty file at `parent/name`, respecting the workspace root.
    @discardableResult
    func createFile(under parent: URL, name: String) throws -> URL {
        try guardInsideWorkspace(parent)
        let clean = try validate(name: name)
        let target = parent.appendingPathComponent(clean)
        if FileManager.default.fileExists(atPath: target.path) { throw FSError.exists(target) }
        do {
            try Data().write(to: target, options: .withoutOverwriting)
        } catch { throw FSError.underlying(error) }
        refresh()
        return target
    }

    @discardableResult
    func createFolder(under parent: URL, name: String) throws -> URL {
        try guardInsideWorkspace(parent)
        let clean = try validate(name: name)
        let target = parent.appendingPathComponent(clean)
        if FileManager.default.fileExists(atPath: target.path) { throw FSError.exists(target) }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } catch { throw FSError.underlying(error) }
        refresh()
        return target
    }

    /// Rename `url` to a sibling with `newName`. Returns the new URL.
    @discardableResult
    func rename(_ url: URL, to newName: String) throws -> URL {
        try guardInsideWorkspace(url)
        let clean = try validate(name: newName)
        let target = url.deletingLastPathComponent().appendingPathComponent(clean)
        if target == url { return url }
        if FileManager.default.fileExists(atPath: target.path) { throw FSError.exists(target) }
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch { throw FSError.underlying(error) }
        refresh()
        return target
    }

    /// Move to Trash.
    func trash(_ url: URL) throws {
        try guardInsideWorkspace(url)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch { throw FSError.underlying(error) }
        refresh()
    }

    // MARK: - Validation

    private func guardInsideWorkspace(_ url: URL) throws {
        let root = rootURL.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p == root || p.hasPrefix(root + "/") else { throw FSError.notInWorkspace }
    }

    private func validate(name raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              trimmed != ".", trimmed != ".." else {
            throw FSError.invalidName
        }
        return trimmed
    }

    // MARK: - Scanning

    private static func scan(url: URL) -> FileNode {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if !isDir {
            return FileNode(url: url, isDirectory: false, children: nil)
        }
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        let sorted = contents.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if aDir != bDir { return aDir && !bDir }         // dirs first
            return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
        }
        let children = sorted.map { scan(url: $0) }
        return FileNode(url: url, isDirectory: true, children: children)
    }
}
