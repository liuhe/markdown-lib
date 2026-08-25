import SwiftUI

/// Right-side outline sidebar. Shows the current tab's ATX headings,
/// indented per level. Clicking a heading asks the editor to scroll it
/// into view via `EditorBridge.scrollToHeading(index:)`.
public struct OutlineView: View {
    @ObservedObject public var store: DocumentStore
    public let onSelect: (Int) -> Void

    @State private var headings: [OutlineEntry] = []

    public init(store: DocumentStore, onSelect: @escaping (Int) -> Void) {
        self.store = store
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Outline")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(headings.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            if headings.isEmpty {
                Spacer()
                Text("No headings")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                List {
                    ForEach(headings) { h in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(repeating: " ", count: max(0, h.level - 1) * 2))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(h.text)
                                .font(.system(size: 12,
                                              weight: h.level <= 1 ? .semibold : .regular))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 1)
                        .padding(.leading, CGFloat(max(0, h.level - 1)) * 10)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(h.index) }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { recompute() }
        .onChange(of: store.text) { _, _ in recompute() }
    }

    private func recompute() {
        headings = MarkdownOutline.headings(in: store.text)
    }
}
