import SwiftUI
import UniformTypeIdentifiers

/// Sidebar file tree for a workspace. Single-click on a text-like file opens
/// it in a new tab (or focuses the existing tab if already open). Right-click
/// / control-click surfaces new / rename / delete / reveal / move actions.
/// Drag a row onto a folder-like row to move.
struct FileTreeView: View {
    @ObservedObject var workspace: WorkspaceStore
    let activeFileURL: URL?

    let onOpen: (URL) -> Void
    let onNewFile: (URL) -> Void          // parent
    let onNewFolder: (URL) -> Void        // parent
    let onRename: (URL) -> Void
    let onDelete: (URL) -> Void
    let onReveal: (URL) -> Void
    let onMove: (URL) -> Void              // menu-driven "Move to…"
    let onDropMove: (URL, URL) -> Void     // (source, target-folder-like)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List {
                if let children = workspace.root.children {
                    OutlineGroup(children, id: \.id, children: \.children) { node in
                        row(for: node)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var header: some View {
        HStack {
            Text(workspace.rootURL.lastPathComponent)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Menu {
                Button("New File at Root")   { onNewFile(workspace.rootURL) }
                Button("New Folder at Root") { onNewFolder(workspace.rootURL) }
                Divider()
                Button("Reveal in Finder")   { onReveal(workspace.rootURL) }
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

    private func row(for node: FileNode) -> some View {
        FileTreeRow(
            node: node,
            isActive: node.url == activeFileURL,
            onOpen: onOpen,
            onNewFile: onNewFile,
            onNewFolder: onNewFolder,
            onRename: onRename,
            onDelete: onDelete,
            onReveal: onReveal,
            onMove: onMove,
            onDropMove: onDropMove
        )
    }
}

/// Extracted so `@State` for hover / drop-highlight lives per row.
private struct FileTreeRow: View {
    let node: FileNode
    let isActive: Bool

    let onOpen: (URL) -> Void
    let onNewFile: (URL) -> Void
    let onNewFolder: (URL) -> Void
    let onRename: (URL) -> Void
    let onDelete: (URL) -> Void
    let onReveal: (URL) -> Void
    let onMove: (URL) -> Void
    let onDropMove: (URL, URL) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        let editable = !node.isDirectory && WorkspaceStore.isEditable(node.url)
        HStack(spacing: 4) {
            Image(systemName: node.isDirectory
                  ? "folder"
                  : (editable ? "doc.text" : "doc"))
                .foregroundStyle(node.isDirectory ? .yellow : .secondary)
                .font(.system(size: 11))
            Text(node.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(editable || node.isDirectory ? .primary : .secondary)
            Spacer()
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .background(rowBackground)
        .cornerRadius(3)
        .onTapGesture {
            guard !node.isDirectory, editable else { return }
            onOpen(node.url)
        }
        .contextMenu {
            if !node.isDirectory && editable {
                Button("Open") { onOpen(node.url) }
                Divider()
            }
            if node.canAcceptChildren {
                Button("New File")   { onNewFile(node.url) }
                Button("New Folder") { onNewFolder(node.url) }
                Divider()
            }
            Button("Rename…") { onRename(node.url) }
            Button("Move to…") { onMove(node.url) }
            Button("Delete", role: .destructive) { onDelete(node.url) }
            Divider()
            Button("Reveal in Finder") { onReveal(node.url) }
        }
        // Drag source — every row is draggable except the workspace root
        // (which the sidebar doesn't render anyway).
        .onDrag { NSItemProvider(object: node.url as NSURL) }
        // Drop target — only folder-like nodes accept moves.
        .modifier(
            DropAcceptingIfPossible(
                canAcceptChildren: node.canAcceptChildren,
                isTargeted: $isDropTargeted,
                targetURL: node.url,
                onDrop: onDropMove
            )
        )
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .background(Color.accentColor.opacity(0.15).cornerRadius(3))
        } else if isActive {
            Color.accentColor.opacity(0.20)
        } else {
            Color.clear
        }
    }
}

/// Attach `.onDrop` only to rows that can host children; keeps other rows
/// out of the drag session entirely so they don't flicker as targets.
private struct DropAcceptingIfPossible: ViewModifier {
    let canAcceptChildren: Bool
    @Binding var isTargeted: Bool
    let targetURL: URL
    let onDrop: (URL, URL) -> Void

    func body(content: Content) -> some View {
        if canAcceptChildren {
            content.onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                loadURL(from: providers.first) { source in
                    guard let source else { return }
                    onDrop(source, targetURL)
                }
                return true
            }
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
