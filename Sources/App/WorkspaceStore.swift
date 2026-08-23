import Foundation
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

/// One open folder. Owns the recursively scanned file tree and re-scans on
/// demand (window activation, explicit refresh).
final class WorkspaceStore: ObservableObject {

    @Published private(set) var rootURL: URL
    @Published private(set) var root: FileNode

    /// File extensions we consider "editable" — used to grey out or hide the
    /// obviously-not-text stuff. Everything else is still shown but flagged.
    static let editableExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt", "text", "rst",
    ]

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.root = Self.scan(url: rootURL)
    }

    func refresh() {
        root = Self.scan(url: rootURL)
    }

    static func isEditable(_ url: URL) -> Bool {
        editableExtensions.contains(url.pathExtension.lowercased())
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
