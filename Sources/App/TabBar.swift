import SwiftUI

/// Horizontal tab strip for a `MarkdownWindowController`. Each tab shows the
/// document's display name, a dirty-indicator dot, and a close ✕. Click a tab
/// to activate; click ✕ or middle-click to close.
struct TabBar: View {
    @ObservedObject var tabs: TabbedDocumentModel
    let onCloseTab: (Int) -> Void
    let onNewTab: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabItem(
                            store: tab.store,
                            isActive: index == tabs.activeIndex,
                            onSelect: { tabs.select(index) },
                            onClose: { onCloseTab(index) }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .help("New Tab (⌘N)")
            .padding(.trailing, 4)
        }
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }
}

private struct TabItem: View {
    @ObservedObject var store: DocumentStore
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(store.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
            if store.isDirty {
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundStyle(.secondary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .foregroundStyle(hovering || isActive ? Color.primary : Color.clear)
            }
            .buttonStyle(.borderless)
            .help("Close Tab (⌘W)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive
                      ? Color(nsColor: .textBackgroundColor)
                      : (hovering ? Color.secondary.opacity(0.08) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}
