import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sidebar file tree for a workspace.
///
/// Built on a *flat* `List` (not `OutlineGroup`) so we can:
///   • carry a `URL?` selection that ↑↓ keyboard nav can move,
///   • expand / collapse dirs ourselves in response to ← / → keys,
///   • keep everything else — context menu, click-to-open, drag & drop —
///     working the way it did.
///
/// Interaction summary:
///   Click a file        → select + open (existing behavior)
///   Click a directory   → select only
///   Click the ▸/▾ chevr → toggle expansion (doesn't move selection)
///   ↑ / ↓               → move selection up / down through visible rows
///   →                   → expand selected dir; if already expanded, jump to first child
///   ←                   → collapse selected dir; if already collapsed, jump to parent
///   Enter / Space       → open (files) or toggle expansion (dirs)
struct FileTreeView: View {
    @ObservedObject var workspace: WorkspaceStore
    let activeFileURL: URL?

    let onOpen: (URL) -> Void
    let onNewFile: (URL) -> Void
    let onNewFolder: (URL) -> Void
    let onRename: (URL) -> Void
    let onDelete: (URL) -> Void
    let onReveal: (URL) -> Void
    let onMove: (URL) -> Void
    let onDropMove: (URL, URL) -> Void

    @State private var expanded: Set<URL> = []
    @State private var selected: URL?
    @FocusState private var focused: Bool

    // MARK: - Flattened items

    /// One visible row in the sidebar. Depth drives indentation; the flat
    /// list is recomputed each render from `workspace.root` + `expanded`.
    private struct FlatItem: Identifiable, Hashable {
        let url: URL
        let name: String
        let depth: Int
        let isDirectory: Bool
        let isFileFolder: Bool
        let canOpen: Bool
        let hasChildren: Bool
        let parentURL: URL?
        var id: URL { url }
    }

    private var items: [FlatItem] {
        var out: [FlatItem] = []
        flatten(workspace.root, depth: -1, parent: nil, into: &out)
        return out
    }

    private func flatten(_ node: FileNode, depth: Int, parent: URL?, into out: inout [FlatItem]) {
        let isSyntheticRoot = (depth < 0)
        if !isSyntheticRoot {
            let hasKids = (node.children?.isEmpty == false)
            let expandable = (node.children != nil)
            out.append(FlatItem(
                url: node.url,
                name: node.name,
                depth: depth,
                isDirectory: node.isDirectory,
                isFileFolder: node.isFileFolder,
                canOpen: !node.isDirectory && WorkspaceStore.isEditable(node.url),
                hasChildren: hasKids && expandable,
                parentURL: parent
            ))
        }
        // Recurse either because we're at the synthetic root (always) or
        // because this node is user-expanded.
        if let children = node.children,
           isSyntheticRoot || expanded.contains(node.url) {
            for c in children {
                flatten(c,
                        depth: depth + 1,
                        parent: isSyntheticRoot ? nil : node.url,
                        into: &out)
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            let flat = items
            List(flat, selection: $selected) { item in
                row(for: item, allItems: flat)
                    .tag(item.url)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 6))
            }
            .listStyle(.sidebar)
            .focused($focused)
            .onKeyPress(.leftArrow)  { handleLeft(items: flat);   return .handled }
            .onKeyPress(.rightArrow) { handleRight(items: flat);  return .handled }
            .onKeyPress(.return)     { handleActivate(items: flat); return .handled }
            .onKeyPress(.space)      { handleActivate(items: flat); return .handled }
            // Empty-area right-click. When SwiftUI picks up the click over
            // an actual row it also routes through this menu with `urls`
            // set to the row's URL — mirror the per-row menu in that case
            // so we don't accidentally drop the row context menu.
            .contextMenu(forSelectionType: URL.self) { urls in
                if urls.isEmpty {
                    Button("New File at Root")   { onNewFile(workspace.rootURL) }
                    Button("New Folder at Root") { onNewFolder(workspace.rootURL) }
                    Divider()
                    Button("Reveal in Finder")   { onReveal(workspace.rootURL) }
                    Button("Copy Path")          { copyPath(workspace.rootURL) }
                }
                // Per-row menu is still supplied via `.contextMenu { … }` on
                // each row, which takes precedence over this list-level menu
                // when the click is on a row.
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(workspace.rootURL.lastPathComponent)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)

            Button(action: revealActiveInTree) {
                Image(systemName: "scope").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(activeFileURL == nil)
            .help("Reveal Active File")

            Button(action: { expanded.removeAll() }) {
                Image(systemName: "rectangle.compress.vertical").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(expanded.isEmpty)
            .help("Collapse All")

            Menu {
                Button("New File at Root")   { onNewFile(workspace.rootURL) }
                Button("New Folder at Root") { onNewFolder(workspace.rootURL) }
                Divider()
                Button("Reveal in Finder")   { onReveal(workspace.rootURL) }
                Button("Copy Path")          { copyPath(workspace.rootURL) }
                Divider()
                Button("Refresh")            { workspace.refresh() }
            } label: {
                Image(systemName: "plus.circle").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Reveal active file

    /// Expand every ancestor node of `activeFileURL` in the tree and set
    /// selection to it. Ancestors are walked through the FileNode graph
    /// (not by path decomposition) so file-folder aliasing — where
    /// `notes.md`'s children come from a sibling `notes/` directory —
    /// works correctly.
    private func revealActiveInTree() {
        guard let target = activeFileURL else { return }
        guard let chain = Self.ancestorURLs(of: target, in: workspace.root) else {
            // Not in the current tree (maybe a loose file was opened, or the
            // tree hasn't finished scanning yet).
            return
        }
        for url in chain where url != workspace.root.url {
            expanded.insert(url)
        }
        selected = target
        focused = true
    }

    /// Depth-first search that returns the URLs of every FileNode on the
    /// path from `node` to a descendant matching `target`, ordered from
    /// deepest ancestor first (nearest to target) up to `node`.
    /// Returns nil if `target` is not reachable from `node`.
    private static func ancestorURLs(of target: URL, in node: FileNode) -> [URL]? {
        if node.url == target { return [] }
        guard let children = node.children else { return nil }
        for c in children {
            if c.url == target { return [node.url] }
            if let sub = ancestorURLs(of: target, in: c) {
                return sub + [node.url]
            }
        }
        return nil
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for item: FlatItem, allItems: [FlatItem]) -> some View {
        let isActive = (item.url == activeFileURL)
        let isSelected = (selected == item.url)

        HStack(spacing: 3) {
            // Indent per depth. 12pt is roughly Finder's step.
            if item.depth > 0 {
                Spacer().frame(width: CGFloat(item.depth) * 12)
            }

            // Disclosure chevron. Clicking it toggles WITHOUT changing
            // selection so users can peek at children without losing where
            // they were.
            if item.hasChildren {
                Image(systemName: expanded.contains(item.url) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 12, height: 14)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleExpansion(item.url) }
            } else {
                Spacer().frame(width: 12)
            }

            Image(systemName: iconName(for: item))
                .foregroundStyle(iconColor(for: item, isSelected: isSelected))
                .font(.system(size: 12))
                .frame(width: 14)

            Text(item.name)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(item.canOpen || item.isDirectory ? .primary : .secondary)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.leading, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selected = item.url
            focused = true
            if item.canOpen { onOpen(item.url) }
        }
        .contextMenu { contextMenu(for: item) }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .modifier(
            DropAcceptingIfPossible(
                canAcceptChildren: item.isDirectory || item.isFileFolder,
                targetURL: item.url,
                onDrop: onDropMove
            )
        )
    }

    // MARK: - Icons

    private func iconName(for item: FlatItem) -> String {
        if item.isDirectory { return "folder.fill" }
        if item.isFileFolder { return "doc.text.fill" }
        if item.canOpen { return "doc.text" }
        return "doc"
    }

    private func iconColor(for item: FlatItem, isSelected: Bool) -> Color {
        // On the selected row, the List paints the accent color as background.
        // A blue folder icon on that blue background disappears, so switch
        // to `.primary` — SwiftUI auto-picks a contrasting foreground for
        // the selection style.
        if isSelected { return .primary }
        if item.isDirectory { return .accentColor }
        if item.isFileFolder { return .accentColor.opacity(0.8) }
        if item.canOpen { return .secondary }
        return .secondary.opacity(0.5)
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for item: FlatItem) -> some View {
        if !item.isDirectory && item.canOpen {
            Button("Open") { onOpen(item.url) }
            Divider()
        }
        if item.isDirectory || WorkspaceStore.isMarkdownFile(item.url) {
            Button("New File")   { onNewFile(item.url) }
            Button("New Folder") { onNewFolder(item.url) }
            Divider()
        }
        Button("Rename…") { onRename(item.url) }
        Button("Move to…") { onMove(item.url) }
        Button("Delete", role: .destructive) { onDelete(item.url) }
        Divider()
        Button("Reveal in Finder") { onReveal(item.url) }
        Button("Copy Path")        { copyPath(item.url) }
    }

    private func copyPath(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)
    }

    // MARK: - Keyboard

    private func toggleExpansion(_ url: URL) {
        if expanded.contains(url) { expanded.remove(url) }
        else { expanded.insert(url) }
    }

    private func handleLeft(items: [FlatItem]) {
        guard let sel = selected,
              let item = items.first(where: { $0.url == sel }) else { return }
        // Expanded dir → collapse; otherwise move to parent.
        if item.hasChildren && expanded.contains(sel) {
            expanded.remove(sel)
        } else if let parent = item.parentURL {
            selected = parent
        }
    }

    private func handleRight(items: [FlatItem]) {
        guard let sel = selected,
              let item = items.first(where: { $0.url == sel }) else { return }
        if item.hasChildren {
            if !expanded.contains(sel) {
                expanded.insert(sel)
            } else {
                // Already open — jump to the first child (which sits right
                // after us in the flat list, at depth+1).
                if let idx = items.firstIndex(where: { $0.url == sel }),
                   idx + 1 < items.count,
                   items[idx + 1].depth == item.depth + 1 {
                    selected = items[idx + 1].url
                }
            }
        }
    }

    private func handleActivate(items: [FlatItem]) {
        guard let sel = selected,
              let item = items.first(where: { $0.url == sel }) else { return }
        if item.canOpen {
            onOpen(sel)
        } else if item.hasChildren {
            toggleExpansion(sel)
        }
    }
}

/// Attach `.onDrop` only to rows that can host children; keeps other rows
/// out of the drag session entirely so they don't flicker as targets.
private struct DropAcceptingIfPossible: ViewModifier {
    let canAcceptChildren: Bool
    let targetURL: URL
    let onDrop: (URL, URL) -> Void

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if canAcceptChildren {
            content.onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                loadURL(from: providers.first) { source in
                    guard let source else { return }
                    onDrop(source, targetURL)
                }
                return true
            }
            .background(
                isTargeted
                ? RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 1.5)
                : nil
            )
        } else {
            content
        }
    }

    private func loadURL(from provider: NSItemProvider?, completion: @escaping (URL?) -> Void) {
        guard let provider else { completion(nil); return }
        _ = provider.loadObject(ofClass: NSURL.self) { obj, _ in
            let url = obj as? URL
            DispatchQueue.main.async { completion(url) }
        }
    }
}
