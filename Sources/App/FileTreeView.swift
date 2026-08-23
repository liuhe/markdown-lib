import SwiftUI

/// Sidebar file tree for a workspace. Single-click on a text-like file opens
/// it in a new tab (or focuses the existing tab if already open). Right-click
/// / control-click surfaces new / rename / delete / reveal actions.
struct FileTreeView: View {
    @ObservedObject var workspace: WorkspaceStore
    let activeFileURL: URL?

    let onOpen: (URL) -> Void
    let onNewFile: (URL) -> Void          // parent
    let onNewFolder: (URL) -> Void        // parent
    let onRename: (URL) -> Void
    let onDelete: (URL) -> Void
    let onReveal: (URL) -> Void

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

    @ViewBuilder
    private func row(for node: FileNode) -> some View {
        let isActive = node.url == activeFileURL
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
        .background(isActive
                    ? Color.accentColor.opacity(0.20)
                    : Color.clear)
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
                // For markdown files, "New File" creates (and if needed
                // materializes) the sibling directory so children show up
                // as descendants of this node.
                Button("New File")   { onNewFile(node.url) }
                Button("New Folder") { onNewFolder(node.url) }
                Divider()
            }
            Button("Rename…") { onRename(node.url) }
            Button("Delete", role: .destructive) { onDelete(node.url) }
            Divider()
            Button("Reveal in Finder") { onReveal(node.url) }
        }
    }
}
