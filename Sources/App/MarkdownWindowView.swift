import SwiftUI

/// Top-level SwiftUI shell for a `MarkdownWindowController`.
/// Layout: [optional sidebar | (tab bar / find bar / editor)].
///
/// All open tabs stay in the view hierarchy (via a ZStack toggling opacity)
/// so their WKWebView keeps its cursor / scroll / undo history across tab
/// switches. Inactive tabs are hidden and non-hit-testable.
struct MarkdownWindowView: View {
    @ObservedObject var tabs: TabbedDocumentModel
    let workspace: WorkspaceStore?

    let onOpenFileFromSidebar: (URL) -> Void
    let onCloseTab: (Int) -> Void
    let onNewTab: () -> Void
    let onNewFile: (URL) -> Void
    let onNewFolder: (URL) -> Void
    let onRename: (URL) -> Void
    let onDelete: (URL) -> Void
    let onReveal: (URL) -> Void
    let onMove: (URL) -> Void
    let onDropMove: (URL, URL) -> Void

    /// Persisted across launches so users don't have to re-toggle.
    /// View → Show Outline (⌥⌘0) flips it via `AppDelegate.toggleOutline`.
    @AppStorage("OutlineVisible") private var outlineVisible: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if let ws = workspace {
                FileTreeView(
                    workspace: ws,
                    activeFileURL: tabs.activeTab?.store.fileURL,
                    onOpen: onOpenFileFromSidebar,
                    onNewFile: onNewFile,
                    onNewFolder: onNewFolder,
                    onRename: onRename,
                    onDelete: onDelete,
                    onReveal: onReveal,
                    onMove: onMove,
                    onDropMove: onDropMove
                )
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 360)
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()
            }

            VStack(spacing: 0) {
                TabBar(tabs: tabs, onCloseTab: onCloseTab, onNewTab: onNewTab)

                if let active = tabs.activeTab, active.bridge.searchVisible {
                    FindBar(bridge: active.bridge).id(active.id)
                }

                ZStack {
                    ForEach(tabs.tabs) { tab in
                        MarkdownWebEditor(store: tab.store, bridge: tab.bridge)
                            .opacity(tab.id == tabs.activeTab?.id ? 1 : 0)
                            .allowsHitTesting(tab.id == tabs.activeTab?.id)
                    }
                    if tabs.tabs.isEmpty {
                        Color(nsColor: .textBackgroundColor)
                        VStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text(workspace != nil
                                 ? "Pick a file in the sidebar, or press ⌘N for a new tab."
                                 : "Press ⌘N for a new tab or ⌘O to open a file.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if outlineVisible, let active = tabs.activeTab {
                Divider()
                OutlineView(store: active.store,
                            onSelect: { active.bridge.scrollToHeading(index: $0) })
                    .id(active.id)
            }
        }
        .frame(minWidth: workspace == nil ? 600 : 800, minHeight: 420)
    }
}
