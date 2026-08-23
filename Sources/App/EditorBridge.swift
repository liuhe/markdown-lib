import Foundation
import WebKit
import AppKit

/// Shared between the window controller, the FindBar (SwiftUI), and the
/// `MarkdownWebEditor` coordinator. Owns the WKWebView reference and exposes
/// a small imperative surface for search / replace commands the SwiftUI layer
/// can call, plus @Published state the FindBar renders.
final class EditorBridge: ObservableObject {

    weak var webView: WKWebView?
    var isEditorReady: Bool = false

    /// Set by the window controller; fired when the JS side asks for a
    /// workspace-file picker (`⌘⇧K` or the Edit menu item). The payload is
    /// the current selection text, or nil if there was none.
    var onFileLinkPickerRequested: ((String?) -> Void)?

    @Published var searchVisible: Bool = false
    @Published var query: String = ""
    @Published var replacement: String = ""
    @Published private(set) var matchCount: Int = 0
    /// 1-based index of the highlighted match. `0` when there are no matches.
    @Published private(set) var currentIndex: Int = 0

    func showFind() {
        searchVisible = true
        if !query.isEmpty { performSearch(scrollToFirst: true) }
    }

    func hideFind() {
        searchVisible = false
        run("window.mdClearSearch && window.mdClearSearch();")
    }

    func performSearch(scrollToFirst: Bool = false) {
        guard isEditorReady else { return }
        let json = jsString(query)
        run("window.mdSearch && window.mdSearch(\(json), \(scrollToFirst ? "true" : "false"));")
    }

    func findNext() {
        guard isEditorReady, !query.isEmpty else { return }
        if matchCount == 0 { NSSound.beep(); return }
        run("window.mdFindStep && window.mdFindStep(1);")
    }

    func findPrev() {
        guard isEditorReady, !query.isEmpty else { return }
        if matchCount == 0 { NSSound.beep(); return }
        run("window.mdFindStep && window.mdFindStep(-1);")
    }

    func replaceCurrent() {
        guard isEditorReady, !query.isEmpty else { return }
        if matchCount == 0 { NSSound.beep(); return }
        run("window.mdReplace && window.mdReplace(\(jsString(replacement)));")
    }

    func replaceAll() {
        guard isEditorReady, !query.isEmpty else { return }
        if matchCount == 0 { NSSound.beep(); return }
        run("window.mdReplaceAll && window.mdReplaceAll(\(jsString(replacement)));")
    }

    // MARK: - Menu-driven picker request
    //
    // Menu → controller → this method. We bounce through JS so the selection
    // text (if any) comes from the editor and drives the label default.

    func requestFileLinkPicker() {
        guard isEditorReady else { return }
        run("window.mdRequestFileLink && window.mdRequestFileLink();")
    }

    // MARK: - Insert link (called after the picker returns)

    func insertLink(href: String, text: String) {
        guard isEditorReady else { return }
        run("window.mdInsertLink && window.mdInsertLink(\(jsString(href)), \(jsString(text)));")
    }

    // MARK: - Outline navigation

    /// Scroll the Nth heading (`<h1>`…`<h6>` in document order) into view.
    func scrollToHeading(index: Int) {
        guard isEditorReady else { return }
        run("window.mdScrollToHeading && window.mdScrollToHeading(\(index));")
    }

    // MARK: - Callbacks from JS

    func updateSearchResult(count: Int, index: Int) {
        matchCount = count
        currentIndex = index
    }

    // MARK: - Private

    private func run(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func jsString(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if c.value < 0x20 {
                    out += String(format: "\\u%04x", c.value)
                } else {
                    out.append(Character(c))
                }
            }
        }
        out += "\""
        return out
    }
}
