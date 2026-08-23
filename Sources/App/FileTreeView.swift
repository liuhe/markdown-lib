import SwiftUI

/// Sidebar file tree for a workspace. Single-click on a text-like file opens
/// it in a new tab (or focuses the existing tab if already open).
struct FileTreeView: View {
    @ObservedObject var workspace: WorkspaceStore
    let activeFileURL: URL?
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(workspace.rootURL.lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button(action: { workspace.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .regular))
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

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
    }
}
