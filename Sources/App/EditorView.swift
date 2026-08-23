import SwiftUI

/// SwiftUI shell hosting the FindBar above the WKWebView editor.
struct EditorView: View {
    @ObservedObject var store: DocumentStore
    @ObservedObject var bridge: EditorBridge

    var body: some View {
        VStack(spacing: 0) {
            if bridge.searchVisible {
                FindBar(bridge: bridge)
            }
            MarkdownWebEditor(markdown: $store.text, bridge: bridge)
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
