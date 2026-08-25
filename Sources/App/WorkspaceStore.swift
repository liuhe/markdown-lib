import Foundation
import AppKit
import Combine
import Darwin

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

    /// Non-hidden directory names we always skip during scans — every one of
    /// them is huge in the wild and none of them ever hold user-editable
    /// markdown. Dotfile dirs (`.git`, `.build`, `.venv`, …) already get
    /// dropped by `.skipsHiddenFiles`.
    private static let ignoredDirectoryNames: Set<String> = [
        "node_modules",
        "build", "dist", "out", "target",
        "Pods", "DerivedData",
        "__pycache__", ".mypy_cache", ".pytest_cache",
        "vendor",
    ]

    /// Directories whose names start with any of these prefixes are also
    /// skipped. Bazel scatters `bazel-<workspace>` symlinks throughout a repo
    /// that point back at massive build output.
    private static let ignoredDirectoryPrefixes: [String] = [
        "bazel-",
    ]

    /// Compiled `.gitignore` matcher — basename-level patterns only, with
    /// fnmatch(3)-style globs so `bazel-*`, `*.log`, etc. work.
    struct IgnoreMatcher {
        let patterns: [String]

        static let empty = IgnoreMatcher(patterns: [])

        static func loadFromWorkspace(_ rootURL: URL) -> IgnoreMatcher {
            let gitignore = rootURL.appendingPathComponent(".gitignore")
            guard let content = try? String(contentsOf: gitignore, encoding: .utf8) else {
                return .empty
            }
            var patterns: [String] = []
            for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
                var line = String(raw).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line.hasPrefix("#") { continue }
                // Negation patterns aren't worth the complexity for us; skip
                // them so we don't accidentally *include* something the user
                // marked back as visible.
                if line.hasPrefix("!") { continue }
                // Directory-only marker (trailing `/`) — strip; we treat the
                // pattern as basename match either way.
                if line.hasSuffix("/") { line.removeLast() }
                // Skip anything with a path separator in the middle — that
                // would require path-aware matching, which we don't do yet.
                // Common monorepo entries (`node_modules`, `bazel-*`, `.env`)
                // are basename patterns, so this still covers the bulk.
                if line.contains("/") { continue }
                patterns.append(line)
            }
            return IgnoreMatcher(patterns: patterns)
        }

        func matches(name: String) -> Bool {
            guard !patterns.isEmpty else { return false }
            return name.withCString { nameC in
                for pat in patterns {
                    let matched = pat.withCString { patC in
                        Darwin.fnmatch(patC, nameC, 0) == 0
                    }
                    if matched { return true }
                }
                return false
            }
        }
    }

    /// Background queue for tree walks. Serial so back-to-back refreshes
    /// don't double-scan; the version counter drops stale results anyway.
    private let scanQueue = DispatchQueue(label: "mdlib.workspace.scan", qos: .userInitiated)

    /// Bumped on every `refresh()` call. The completion handler on `scanQueue`
    /// only publishes if its version still matches — coalesces bursts and
    /// prevents an old, slow scan from clobbering a newer result.
    private var scanVersion: UInt64 = 0

    /// Latest `.gitignore` matcher — reloaded on every refresh so pattern
    /// edits take effect on the next scan, and also queried by the FSEvents
    /// filter path to decide whether an event batch is worth rescanning for.
    private var currentIgnore: IgnoreMatcher = .empty

    init(rootURL: URL) {
        self.rootURL = rootURL
        // Placeholder empty tree so the sidebar shows immediately with the
        // right root name; the real scan fills it in via `refresh()` below.
        self.root = FileNode(url: rootURL, isDirectory: true, children: [])
        startWatching()
        refresh()
    }

    deinit { watcher?.stop() }

    /// Kick off a scan on the background queue and publish the result on
    /// main when it's the freshest one. Cheap on the calling thread — no
    /// filesystem work happens here. `.gitignore` is re-parsed on each
    /// refresh (tiny file) so pattern edits take effect on the next FSEvent
    /// tick, and the parsed matcher is cached for the FSEvents-path filter.
    func refresh() {
        let matcher = IgnoreMatcher.loadFromWorkspace(rootURL)
        currentIgnore = matcher
        scanVersion &+= 1
        let version = scanVersion
        let url = rootURL
        scanQueue.async { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            let node = Self.scan(url: url, ignore: matcher)
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            if elapsed > PerfLog.slowBlockThreshold {
                PerfLog.write("⚠️ [slow] WorkspaceStore.scan(\(url.lastPathComponent)): \(PerfLog.ms(elapsed)) ms (background, \(matcher.patterns.count) gitignore rules)")
            }
            DispatchQueue.main.async {
                guard let self, version == self.scanVersion else { return }
                PerfLog.measure("WorkspaceStore.publish(\(url.lastPathComponent))") {
                    self.root = node
                }
            }
        }
    }

    /// Decide whether an FSEvents batch is worth rescanning for. Returns
    /// `true` when at least one changed path lives outside every ignored
    /// subtree; `false` when every path is inside `node_modules`, `.git`,
    /// `bazel-out`, a `.gitignore`d dir, etc.
    private func shouldRescan(for changedPaths: [String]) -> Bool {
        guard !changedPaths.isEmpty else { return true }
        let rootPath = rootURL.standardizedFileURL.path
        for path in changedPaths {
            let std = URL(fileURLWithPath: path).standardizedFileURL.path
            // Anything outside the root or the root itself: rescan.
            if !std.hasPrefix(rootPath + "/") { return true }
            let suffix = String(std.dropFirst(rootPath.count + 1))
            // Walk components; if any ancestor component is an ignored dir,
            // the leaf change is confined to noise and this path can be
            // skipped. Otherwise this path forces a rescan.
            var confined = false
            for c in suffix.split(separator: "/") {
                let comp = String(c)
                if isIgnoredComponent(comp) { confined = true; break }
            }
            if !confined { return true }
        }
        return false
    }

    private func isIgnoredComponent(_ c: String) -> Bool {
        // Hidden dir prefixes cover .git / .idea / .venv / .DS_Store and the
        // like, all of which get very chatty during background work.
        if c.hasPrefix(".") { return true }
        // X.assets/ is hidden from the sidebar and doesn't need rescan
        // notifications when the editor drops paste-… files into it.
        if c.hasSuffix(".assets") { return true }
        if Self.ignoredDirectoryNames.contains(c) { return true }
        for p in Self.ignoredDirectoryPrefixes where c.hasPrefix(p) { return true }
        if currentIgnore.matches(name: c) { return true }
        return false
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

    /// The paste-image assets directory URL for a markdown file:
    /// `<basename>.assets` sibling. Purely a naming derivation — the
    /// directory is created lazily on the first image paste and is hidden
    /// from the sidebar when the paired markdown file exists.
    static func assetsDirectoryURL(for markdownURL: URL) -> URL {
        markdownURL
            .deletingPathExtension()
            .appendingPathExtension("assets")
    }

    // MARK: - Watching

    private func startWatching() {
        watcher = FileTreeWatcher(url: rootURL) { [weak self] paths in
            guard let self else { return }
            if self.shouldRescan(for: paths) {
                Self.logFSEventTrigger(paths: paths, rootURL: self.rootURL)
                self.refresh()
            }
        }
    }

    /// Print who fired the rescan. Basename-only sample plus the count so we
    /// can spot noisy sources (git, IDE, Time Machine, Spotlight) without
    /// dumping full paths.
    private static func logFSEventTrigger(paths: [String], rootURL: URL) {
        let rootPath = rootURL.standardizedFileURL.path
        let sample = paths.prefix(4).map { p -> String in
            let std = URL(fileURLWithPath: p).standardizedFileURL.path
            if std.hasPrefix(rootPath + "/") {
                return String(std.dropFirst(rootPath.count + 1))
            }
            return std
        }.joined(separator: ", ")
        let more = paths.count > 4 ? " (+\(paths.count - 4) more)" : ""
        PerfLog.write("[fsevents] rescan: \(paths.count) path(s): \(sample)\(more)")
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

            // Same treatment for the paste-image `X.assets/` sibling.
            let oldAssets = Self.assetsDirectoryURL(for: url)
            var assetsIsDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: oldAssets.path, isDirectory: &assetsIsDir),
               assetsIsDir.boolValue {
                let newAssets = Self.assetsDirectoryURL(for: target)
                if !FileManager.default.fileExists(atPath: newAssets.path) {
                    do {
                        try FileManager.default.moveItem(at: oldAssets, to: newAssets)
                        renames.append((oldAssets, newAssets))
                    } catch { throw FSError.underlying(error) }
                }
            }
        }

        refresh()
        return renames
    }

    /// Move `url` into `newParent`. Keeps the source's basename; if a name
    /// clash exists at the destination the caller sees `.exists`. When
    /// `newParent` is a markdown file the routing goes through its companion
    /// directory (creating it lazily), so drop-onto-markdown works the same
    /// as create-inside-markdown.
    ///
    /// For a file-folder source (markdown + companion dir), the companion
    /// dir moves along with the file. Returns every rename that happened so
    /// the caller can rebase open tabs.
    @discardableResult
    func move(_ url: URL, into newParent: URL) throws -> [(from: URL, to: URL)] {
        try guardInsideWorkspace(url)
        let destDir = try resolveParentDirectory(newParent)

        // No-op: dropped into current parent.
        if url.deletingLastPathComponent().standardizedFileURL == destDir.standardizedFileURL {
            return []
        }
        // Guard: don't move a directory into itself or its own descendant.
        let sourcePath = url.standardizedFileURL.path
        let destPath = destDir.standardizedFileURL.path
        if destPath == sourcePath || destPath.hasPrefix(sourcePath + "/") {
            throw FSError.invalidName
        }
        // Also prevent moving a markdown into its own companion dir (would
        // orphan the pairing).
        if Self.isMarkdownFile(url) {
            let companionPath = Self.companionDirectoryURL(for: url).standardizedFileURL.path
            if destPath == companionPath || destPath.hasPrefix(companionPath + "/") {
                throw FSError.invalidName
            }
        }

        let target = destDir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) { throw FSError.exists(target) }

        var renames: [(from: URL, to: URL)] = []
        do {
            try FileManager.default.moveItem(at: url, to: target)
            renames.append((url, target))
        } catch { throw FSError.underlying(error) }

        // File-folder: also move the companion dir when the source was one.
        if Self.isMarkdownFile(url) {
            let oldCompanion = Self.companionDirectoryURL(for: url)
            var isDirBool: ObjCBool = false
            if FileManager.default.fileExists(atPath: oldCompanion.path, isDirectory: &isDirBool),
               isDirBool.boolValue {
                let basename = target.deletingPathExtension().lastPathComponent
                let newCompanion = destDir.appendingPathComponent(basename)
                if !FileManager.default.fileExists(atPath: newCompanion.path) {
                    do {
                        try FileManager.default.moveItem(at: oldCompanion, to: newCompanion)
                        renames.append((oldCompanion, newCompanion))
                    } catch { throw FSError.underlying(error) }
                }
            }
            // Same for the `.assets/` sibling.
            let oldAssets = Self.assetsDirectoryURL(for: url)
            var assetsIsDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: oldAssets.path, isDirectory: &assetsIsDir),
               assetsIsDir.boolValue {
                let basename = target.deletingPathExtension().lastPathComponent
                let newAssets = destDir.appendingPathComponent(basename + ".assets")
                if !FileManager.default.fileExists(atPath: newAssets.path) {
                    do {
                        try FileManager.default.moveItem(at: oldAssets, to: newAssets)
                        renames.append((oldAssets, newAssets))
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
            // Same for the paste-image `.assets/` sibling.
            let assets = Self.assetsDirectoryURL(for: url)
            var assetsIsDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: assets.path, isDirectory: &assetsIsDir),
               assetsIsDir.boolValue {
                do {
                    try FileManager.default.trashItem(at: assets, resultingItemURL: nil)
                    trashed.append(assets)
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
    private static func shouldIgnoreDirectory(named name: String) -> Bool {
        if ignoredDirectoryNames.contains(name) { return true }
        for p in ignoredDirectoryPrefixes where name.hasPrefix(p) { return true }
        return false
    }

    private static func scan(url: URL, ignore: IgnoreMatcher) -> FileNode {
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

        // Cache the `isDirectory` lookup once per URL + drop noise directories
        // eagerly. The `resourceValues` call is a stat() under the hood; doing
        // it three times per URL (bucketing / adopting / sorting) added up in
        // large repos.
        struct Entry { let url: URL; let isDirectory: Bool }
        var entries: [Entry] = []
        entries.reserveCapacity(contents.count)
        for item in contents {
            let name = item.lastPathComponent
            let itemIsDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if itemIsDir && shouldIgnoreDirectory(named: name) { continue }
            if ignore.matches(name: name) { continue }
            entries.append(Entry(url: item, isDirectory: itemIsDir))
        }

        // Bucket by (name, is-dir) so we can pair .md files with dirs of the
        // same basename.
        var dirsByName: [String: URL] = [:]
        var filesByBasename: [String: [URL]] = [:]  // basename → matching files

        for e in entries {
            if e.isDirectory {
                dirsByName[e.url.lastPathComponent] = e.url
            } else if markdownExtensions.contains(e.url.pathExtension.lowercased()) {
                let basename = e.url.deletingPathExtension().lastPathComponent
                filesByBasename[basename, default: []].append(e.url)
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

        // Assets dirs (`X.assets/`) are hidden from the sidebar entirely
        // when the paired markdown file (`X.md`, `X.markdown`, …) exists
        // as a sibling. They hold paste-image blobs that clutter navigation.
        var hiddenAssetDirs: Set<URL> = []
        for e in entries where e.isDirectory {
            let name = e.url.lastPathComponent
            guard name.hasSuffix(".assets") else { continue }
            let base = String(name.dropLast(".assets".count))
            if !base.isEmpty, !(filesByBasename[base] ?? []).isEmpty {
                hiddenAssetDirs.insert(e.url)
            }
        }

        // Build children. Skip adopted dirs; upgrade adopter .mds to
        // file-folder nodes that carry the (recursively scanned) dir's
        // children.
        var childNodes: [FileNode] = []
        for e in entries {
            let item = e.url
            let itemIsDir = e.isDirectory
            if itemIsDir {
                if adoptedDirs.contains(item) { continue }
                if hiddenAssetDirs.contains(item) { continue }
                childNodes.append(scan(url: item, ignore: ignore))
            } else if let companion = mdAdopters[item] {
                let dirNode = scan(url: companion, ignore: ignore)
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
