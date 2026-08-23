import Foundation
import Combine

/// One editable document that lives inside a `MarkdownWindowController`'s tab
/// strip. Bundles the per-doc `DocumentStore` with its own `EditorBridge` so
/// each tab's search state (query, match count, current index) is independent.
final class DocumentTab: Identifiable, ObservableObject {
    let id = UUID()
    let store: DocumentStore
    let bridge: EditorBridge

    init(store: DocumentStore = DocumentStore()) {
        self.store = store
        self.bridge = EditorBridge()
    }
}

/// The collection of open tabs inside one window plus the currently active
/// index. All mutations go through here so the SwiftUI shell can observe.
final class TabbedDocumentModel: ObservableObject {

    @Published var tabs: [DocumentTab] = []
    @Published var activeIndex: Int = 0

    var activeTab: DocumentTab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    // MARK: - Mutation

    @discardableResult
    func addBlank() -> DocumentTab {
        let tab = DocumentTab()
        tabs.append(tab)
        activeIndex = tabs.count - 1
        return tab
    }

    /// If a tab already has this URL open, focus it. Otherwise create a new tab
    /// (or reuse the trailing clean untitled tab if there is one).
    @discardableResult
    func open(url: URL) throws -> DocumentTab {
        if let idx = tabs.firstIndex(where: { $0.store.fileURL == url }) {
            activeIndex = idx
            return tabs[idx]
        }
        let store = DocumentStore()
        try store.read(from: url)
        let tab = DocumentTab(store: store)

        if let cleanIdx = tabs.firstIndex(where: { $0.store.fileURL == nil && !$0.store.isDirty }) {
            tabs[cleanIdx] = tab
            activeIndex = cleanIdx
        } else {
            tabs.append(tab)
            activeIndex = tabs.count - 1
        }
        return tab
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
    }

    /// Remove the tab at `index`. Returns `true` when the model is now empty
    /// so the window controller can close its window.
    @discardableResult
    func remove(at index: Int) -> Bool {
        guard tabs.indices.contains(index) else { return false }
        tabs.remove(at: index)
        if tabs.isEmpty {
            activeIndex = 0
            return true
        }
        if activeIndex >= tabs.count { activeIndex = tabs.count - 1 }
        return false
    }

    // MARK: - Convenience navigation

    func selectNext() {
        guard !tabs.isEmpty else { return }
        activeIndex = (activeIndex + 1) % tabs.count
    }

    func selectPrevious() {
        guard !tabs.isEmpty else { return }
        activeIndex = (activeIndex - 1 + tabs.count) % tabs.count
    }

    func selectAbsolute(_ oneBasedIndex: Int) {
        let idx = oneBasedIndex - 1
        if tabs.indices.contains(idx) { activeIndex = idx }
    }
}
