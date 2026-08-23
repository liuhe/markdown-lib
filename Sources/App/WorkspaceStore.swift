import Foundation
import AppKit
import Combine

/// One node in the workspace file tree.
///
/// - Regular directory: `isDirectory = true`, `children` non-nil.
/// - Regular file (leaf): `isDirectory = false`, `children = nil`.
/// - **File-folder** (a markdown file with a same-basename sibling
///   directory): `isDirectory = false`, `children` non-nil (taken from the
///   sibling directory), `companionDirectoryURL` set to that directory.
struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let children: [FileNode]?
    let companionDirectoryURL: URL?

    init(url: URL, isDirectory: Bool, children: [FileNode]?, companionDirectoryURL: URL? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
        self.companionDirectoryURL = companionDirectoryURL
    }

    var id: URL { url }
    var name: String { url.lastPathComponent }

    /// True for a markdown file that has adopted a sibling directory's
    /// contents as its own children.
    var isFileFolder: Bool { companionDirectoryURL != nil }

    /// A node the sidebar treats as an expandable "container" — regular dirs
    /// plus file-folders. Sorts before regular files.
    var isFolderLike: Bool { isDirectory || isFileFolder }

    /// Can accept New File / New Folder from the sidebar. Directories always;
    /// markdown files also (they'll grow / adopt a companion dir on demand).
    var canAcceptChildren: Bool {
        isDirectory || WorkspaceStore.isMarkdownFile(url)
    }
}

/// One open folder. Owns the recursively scanned file tree, plus an FSEvents
/// watcher that refreshes it on any change under the root. Also exposes the
/// filesystem operations exercised by the sidebar context menu.
final class WorkspaceStore: ObservableObject {

    @Published private(set) var rootURL: URL
    @Published private(set) var root: FileNode

    private var watcher: FileTreeWatcher?

    /// File extensions that get the "file-folder" treatment (may adopt a
    /// same-basename sibling directory).
    static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd",
    ]

    /// Files the sidebar considers openable in the editor. Superset of
    /// `markdownExtensions`.
    static let editableExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt", "text", "rst",
    ]

    /// Precedence when several markdown files share a basename with a dir
    /// (e.g. both `notes.md` and `notes.markdown` next to `notes/`). Lower
    /// index wins; the winner absorbs the dir, the losers stay as leaves.
    private static let markdownExtensionPriority: [String] =
        ["md", "markdown", "mdown", "mkd"]

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

    static func isMarkdownFile(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// The companion directory URL for a markdown file: sibling with the
    /// same basename, no extension. Purely a naming derivation — the
    /// directory may or may not exist on disk.
    static func companionDirectoryURL(for markdownURL: URL) -> URL {
        markdownURL.deletingPathExtension()
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
        case notContainer(URL)
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .invalidName: return "Invalid file name."
            case .exists(let url): return "“\(url.lastPathComponent)” already exists."
            case .notInWorkspace: return "That path is outside the workspace."
            case .notContainer(let url): return "“\(url.lastPathComponent)” can't contain files."
            case .underlying(let err): return err.localizedDescription
            }
        }
    }

    /// Create an empty file at `parent/name`, respecting the workspace root.
    /// If `parent` is a markdown file, resolves to its companion directory
    /// (creating it lazily when missing).
    @discardableResult
    func createFile(under parent: URL, name: String) throws -> URL {
        let dir = try resolveParentDirectory(parent)
        let clean = try validate(name: name)
        let target = dir.appendingPathComponent(clean)
        if FileManager.default.fileExists(atPath: target.path) { throw FSError.exists(target) }
        do {
            try Data().write(to: target, options: .withoutOverwriting)
        } catch { throw FSError.underlying(error) }
        refresh()
        return target
    }

    @discardableResult
    func createFolder(under parent: URL, name: String) throws -> URL {
        let dir = try resolveParentDirectory(parent)
        let clean = try validate(name: name)
        let target = dir.appendingPathComponent(clean)
        if FileManager.default.fileExists(atPath: target.path) { throw FSError.exists(target) }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } catch { throw FSError.underlying(error) }
        refresh()
        return target
    }

    /// Rename `url` to a sibling with `newName`. Returns the list of renames
    /// that were performed — always at least one (the primary), plus a
    /// second entry for the companion directory when renaming a markdown
    /// file that had one.
    @discardableResult
    func rename(_ url: URL, to newName: String) throws -> [(from: URL, to: URL)] {
        try guardInsideWorkspace(url)
        let clean = try validate(name: newName)
        let target = url.deletingLastPathComponent().appendingPathComponent(clean)
        if target == url { return [] }
        if FileManager.default.fileExists(atPath: target.path) { throw FSError.exists(target) }

        var renames: [(from: URL, to: URL)] = []
        do {
            try FileManager.default.moveItem(at: url, to: target)
            renames.append((url, target))
        } catch { throw FSError.underlying(error) }

        // If we just renamed a markdown file with an existing companion
        // directory, rename the directory too so the two stay coupled.
        if Self.isMarkdownFile(url) {
            let oldCompanion = Self.companionDirectoryURL(for: url)
            var isDirBool: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: oldCompanion.path, isDirectory: &isDirBool
            )
            if exists && isDirBool.boolValue {
                let newBasename = target.deletingPathExtension().lastPathComponent
                let newCompanion = oldCompanion
                    .deletingLastPathComponent()
                    .appendingPathComponent(newBasename)
                if !FileManager.default.fileExists(atPath: newCompanion.path) {
                    do {
                        try FileManager.default.moveItem(at: oldCompanion, to: newCompanion)
                        renames.append((oldCompanion, newCompanion))
                    } catch { throw FSError.underlying(error) }
                }
            }
        }

        refresh()
        return renames
    }

    /// Move to Trash. Returns the list of URLs actually trashed — the file
    /// itself plus its companion directory when the file was a markdown with
    /// one alongside.
    @discardableResult
    func trash(_ url: URL) throws -> [URL] {
        try guardInsideWorkspace(url)
        var trashed: [URL] = []
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            trashed.append(url)
        } catch { throw FSError.underlying(error) }

        if Self.isMarkdownFile(url) {
            let companion = Self.companionDirectoryURL(for: url)
            var isDirBool: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: companion.path, isDirectory: &isDirBool
            )
            if exists && isDirBool.boolValue {
                do {
                    try FileManager.default.trashItem(at: companion, resultingItemURL: nil)
                    trashed.append(companion)
                } catch { throw FSError.underlying(error) }
            }
        }

        refresh()
        return trashed
    }

    /// True if `url` is a markdown file with a real, existing companion dir.
    func hasCompanionDirectory(_ url: URL) -> Bool {
        guard Self.isMarkdownFile(url) else { return false }
        let companion = Self.companionDirectoryURL(for: url)
        var isDirBool: ObjCBool = false
        return FileManager.default.fileExists(atPath: companion.path, isDirectory: &isDirBool)
            && isDirBool.boolValue
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

    /// If `parent` is a real directory return it as-is; if it's a markdown
    /// file, return its companion directory (creating it on demand). Anything
    /// else is a caller bug.
    private func resolveParentDirectory(_ parent: URL) throws -> URL {
        try guardInsideWorkspace(parent)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir) else {
            throw FSError.notContainer(parent)
        }
        if isDir.boolValue { return parent }
        guard Self.isMarkdownFile(parent) else { throw FSError.notContainer(parent) }
        let companion = Self.companionDirectoryURL(for: parent)
        var companionIsDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: companion.path, isDirectory: &companionIsDir) {
            if companionIsDir.boolValue { return companion }
            // Something with that name exists but isn't a directory.
            throw FSError.exists(companion)
        }
        do {
            try FileManager.default.createDirectory(at: companion, withIntermediateDirectories: false)
        } catch { throw FSError.underlying(error) }
        return companion
    }

    // MARK: - Scanning

    /// Recursively build the tree rooted at `url`. Folds each markdown file
    /// that has a same-basename sibling directory into a single "file-folder"
    /// node, hiding the directory itself so the sidebar shows one line.
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

        // Bucket by (name, is-dir) so we can pair .md files with dirs of the
        // same basename.
        var dirsByName: [String: URL] = [:]
        var filesByBasename: [String: [URL]] = [:]  // basename → matching files

        for item in contents {
            let itemIsDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if itemIsDir {
                dirsByName[item.lastPathComponent] = item
            } else if markdownExtensions.contains(item.pathExtension.lowercased()) {
                let basename = item.deletingPathExtension().lastPathComponent
                filesByBasename[basename, default: []].append(item)
            }
        }

        // Decide which dirs are "adopted" by an .md sibling. Resolve
        // multi-extension conflicts via markdownExtensionPriority.
        var adoptedDirs: Set<URL> = []
        var mdAdopters: [URL: URL] = [:]   // md URL → dir URL it adopts
        for (basename, mdURLs) in filesByBasename {
            guard let dir = dirsByName[basename] else { continue }
            let winner = mdURLs.min { a, b in
                let ai = markdownExtensionPriority.firstIndex(of: a.pathExtension.lowercased()) ?? Int.max
                let bi = markdownExtensionPriority.firstIndex(of: b.pathExtension.lowercased()) ?? Int.max
                if ai != bi { return ai < bi }
                return a.lastPathComponent < b.lastPathComponent
            }
            guard let winnerURL = winner else { continue }
            adoptedDirs.insert(dir)
            mdAdopters[winnerURL] = dir
        }

        // Build children. Skip adopted dirs; upgrade adopter .mds to
        // file-folder nodes that carry the (recursively scanned) dir's
        // children.
        var childNodes: [FileNode] = []
        for item in contents {
            let itemIsDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if itemIsDir {
                if adoptedDirs.contains(item) { continue }
                childNodes.append(scan(url: item))
            } else if let companion = mdAdopters[item] {
                let dirNode = scan(url: companion)
                childNodes.append(FileNode(
                    url: item,
                    isDirectory: false,
                    children: dirNode.children ?? [],
                    companionDirectoryURL: companion
                ))
            } else {
                childNodes.append(FileNode(url: item, isDirectory: false, children: nil))
            }
        }

        // Sort: folder-like first (real dirs + file-folders), then leaves;
        // within each bucket, case-insensitive by name.
        childNodes.sort { a, b in
            if a.isFolderLike != b.isFolderLike { return a.isFolderLike && !b.isFolderLike }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        return FileNode(url: url, isDirectory: true, children: childNodes)
    }
}
