import SwiftUI

/// Modal file picker used by `Cmd+Shift+K` / Edit → Insert Link to File….
/// A search field on top; a list of the workspace's markdown files below.
/// Enter picks the highlighted row; Esc cancels; double-click picks.
struct FileLinkPicker: View {

    let files: [URL]
    let workspaceRoot: URL
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""
    @State private var selectedID: URL?
    @FocusState private var searchFocused: Bool

    private var filtered: [URL] {
        guard !query.isEmpty else { return files }
        let q = query.lowercased()
        return files.filter { url in
            url.lastPathComponent.lowercased().contains(q)
                || relativeDisplay(url).lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search workspace files…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(commit)
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(10)

            Divider()

            List(selection: $selectedID) {
                ForEach(filtered, id: \.self) { url in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                        Spacer()
                        Text(relativeDisplay(url))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .tag(url)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onPick(url) }
                }
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 320, idealHeight: 400)
        .onAppear {
            searchFocused = true
            if selectedID == nil { selectedID = filtered.first }
        }
        .onChange(of: query) { _, _ in
            // Snap the selection to the first match whenever the filter changes
            // — otherwise Enter would submit a hidden/stale row.
            selectedID = filtered.first
        }
    }

    private func commit() {
        if let id = selectedID, filtered.contains(id) {
            onPick(id)
            return
        }
        if let first = filtered.first {
            onPick(first)
        }
    }

    private func relativeDisplay(_ url: URL) -> String {
        let rootPath = workspaceRoot.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p == rootPath { return "" }
        if p.hasPrefix(rootPath + "/") { return String(p.dropFirst(rootPath.count + 1)) }
        return p
    }
}
