import SwiftUI

/// Modal file picker used by both **Go to File… (⌘P)** and
/// **Insert Link to File… (⇧⌘K)** — the UI is the same, only the pick
/// callback differs.
///
/// Search field on top; ranked list below. Enter picks the highlighted row;
/// Esc cancels; double-click picks.
///
/// Ranking uses a simple fuzzy score: letters of the query must appear in
/// order in the candidate, with bonuses for consecutive matches and for
/// matches at word boundaries (`-` / `_` / `/` / `.` / space).
struct WorkspaceFilePicker: View {

    let title: String
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
        var scored: [(URL, Int)] = []
        scored.reserveCapacity(files.count)
        for url in files {
            // Basename first — a match there ranks strictly above a match in
            // the surrounding path.
            let base = url.lastPathComponent.lowercased()
            if let s = Self.fuzzyScore(query: q, candidate: base) {
                scored.append((url, s + 100))
                continue
            }
            let rel = relativeDisplay(url).lowercased()
            if let s = Self.fuzzyScore(query: q, candidate: rel) {
                scored.append((url, s))
            }
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(title, text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(commit)
                    // Up / Down on the search field move the highlight in
                    // the result list below without giving up focus.
                    .onKeyPress(.upArrow)   { moveSelection(-1); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(1);  return .handled }
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(10)

            Divider()

            ScrollViewReader { scrollProxy in
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
                        .id(url)  // for ScrollViewReader.scrollTo
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { onPick(url) }
                    }
                }
                .listStyle(.plain)
                .onChange(of: selectedID) { _, new in
                    guard let new else { return }
                    withAnimation(.none) {
                        scrollProxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 320, idealHeight: 400)
        .onAppear {
            searchFocused = true
            if selectedID == nil { selectedID = filtered.first }
        }
        .onChange(of: query) { _, _ in
            selectedID = filtered.first
        }
    }

    /// Move the highlighted row by `delta` (clamped to the visible list).
    /// Called from the ⬆︎/⬇︎ key handlers on the search field so users can
    /// navigate without leaving the input.
    private func moveSelection(_ delta: Int) {
        let list = filtered
        guard !list.isEmpty else { return }
        if let sel = selectedID, let idx = list.firstIndex(of: sel) {
            let newIdx = max(0, min(list.count - 1, idx + delta))
            selectedID = list[newIdx]
        } else {
            // No selection yet: land on the top row on ↓, bottom on ↑.
            selectedID = delta >= 0 ? list.first : list.last
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

    // MARK: - Fuzzy scoring

    /// Returns nil when the letters of `query` can't be matched in order
    /// inside `candidate`. Otherwise a positive score — higher = better.
    /// +1 per matched letter, +2 for each consecutive match, +5 when the
    /// letter lands at a word boundary.
    private static func fuzzyScore(query: String, candidate: String) -> Int? {
        let q = Array(query)
        let c = Array(candidate)
        var qi = 0
        var score = 0
        var consecutive = 0
        var lastWasBoundary = true
        for ch in c {
            let boundary = lastWasBoundary
            lastWasBoundary = (ch == "-" || ch == "_" || ch == "/" || ch == "." || ch == " ")
            if qi < q.count && ch == q[qi] {
                score += 1 + (consecutive * 2) + (boundary ? 5 : 0)
                consecutive += 1
                qi += 1
            } else {
                consecutive = 0
            }
        }
        return qi >= q.count ? score : nil
    }
}

// Backwards-compat alias for any call site that hasn't migrated yet.
typealias FileLinkPicker = WorkspaceFilePicker
