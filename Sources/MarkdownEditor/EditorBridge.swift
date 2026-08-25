import Foundation
import WebKit
import AppKit

/// Imperative surface + `@Published` search state for a single
/// `MarkdownWebEditor` instance. Host apps get a bridge back with the
/// editor and configure the callbacks below to decide how link clicks,
/// drops, and image pastes get handled.
public final class EditorBridge: ObservableObject {

    public init() {}

    // MARK: - Wired by MarkdownWebEditor

    /// The web view backing this editor. Set by `MarkdownWebEditor` when
    /// its `NSViewRepresentable` builds the view. Weakly held so the
    /// bridge can outlive tab teardown without pinning the WKWebView.
    public weak var webView: WKWebView?

    /// True once Toast UI Editor has posted its `ready` message. Guards
    /// the imperative helpers so hosts calling them early do nothing
    /// (rather than blowing up on an unloaded editor).
    public var isEditorReady: Bool = false

    // MARK: - Host-supplied hooks

    /// When non-nil, resolves the workspace root used as a *secondary*
    /// base for relative link resolution. `⌘+click` on a backticked
    /// `notes/index.md` tries this after the current file's directory.
    public var workspaceRootURL: URL?

    /// Called with an already-resolved absolute URL when the user clicks
    /// a link (`⌘+click` on an anchor or backticked path). Host decides
    /// how to open it — spawn a tab, hand off to `NSWorkspace`, whatever.
    /// If nil, non-`file://` URLs go to `NSWorkspace.shared.open` and
    /// `file://` URLs are ignored.
    public var onOpenLink: ((URL) -> Void)?

    /// Called when a file / folder URL is dropped onto the editor's
    /// WKWebView. Nil = ignore drops.
    public var onDropURL: ((URL) -> Void)?

    /// Called when the user pastes / drops an image blob. Return the URL
    /// where the host saved it; the library will relativize against the
    /// current file and insert `![](rel/path)` for you. Return `nil` to
    /// reject the paste.
    public var onPasteImage: ((_ data: Data, _ mime: String) -> URL?)?

    /// Menu / shortcut hook: fired when the JS side asks for a workspace-
    /// file picker (`⌘⇧K` — Insert Link to File… — from the editor). The
    /// payload is the current selection text, or nil if none.
    public var onFileLinkPickerRequested: ((String?) -> Void)?

    // MARK: - Search / replace state (observed by FindBar)

    @Published public var searchVisible: Bool = false
    @Published public var query: String = ""
    @Published public var replacement: String = ""
    @Published public private(set) var matchCount: Int = 0
    /// 1-based index of the highlighted match. `0` when there are none.
    @Published public private(set) var currentIndex: Int = 0

    public func showFind() {
        searchVisible = true
        if !query.isEmpty { performSearch(scrollToFirst: true) }
    }

    public func hideFind() {
        searchVisible = false
        run("window.mdClearSearch && window.mdClearSearch();")
    }

    public func performSearch(scrollToFirst: Bool = false) {
        guard isEditorReady else { return }
        let json = jsString(query)
        run("window.mdSearch && window.mdSearch(\(json), \(scrollToFirst ? "true" : "false"));")
    }

    public func findNext() {
        guard isEditorReady, !query.isEmpty else { return }
        if matchCount == 0 { NSSound.beep(); return }
        run("window.mdFindStep && window.mdFindStep(1);")
    }

    public func findPrev() {
        guard isEditorReady, !query.isEmpty else { return }
        if matchCount == 0 { NSSound.beep(); return }
        run("window.mdFindStep && window.mdFindStep(-1);")
    }

    public func replaceCurrent() {
        guard isEditorReady, !query.isEmpty else { return }
        if matchCount == 0 { NSSound.beep(); return }
        run("window.mdReplace && window.mdReplace(\(jsString(replacement)));")
    }

    public func replaceAll() {
        guard isEditorReady, !query.isEmpty else { return }
        if matchCount == 0 { NSSound.beep(); return }
        run("window.mdReplaceAll && window.mdReplaceAll(\(jsString(replacement)));")
    }

    // MARK: - Menu-driven picker request

    public func requestFileLinkPicker() {
        guard isEditorReady else { return }
        run("window.mdRequestFileLink && window.mdRequestFileLink();")
    }

    // MARK: - Insert link (called after the picker returns)

    public func insertLink(href: String, text: String) {
        guard isEditorReady else { return }
        run("window.mdInsertLink && window.mdInsertLink(\(jsString(href)), \(jsString(text)));")
    }

    // MARK: - Outline navigation

    /// Scroll the Nth heading (`<h1>`…`<h6>` in document order) into view.
    public func scrollToHeading(index: Int) {
        guard isEditorReady else { return }
        run("window.mdScrollToHeading && window.mdScrollToHeading(\(index));")
    }

    // MARK: - Format commands

    /// Delegate to Toast UI Editor's `exec(command, payload)`. Payload
    /// keys are command-specific (e.g., `heading` takes `{ level: N }`).
    public func execCommand(_ command: String, payload: [String: Any]? = nil) {
        guard isEditorReady else { return }
        let payloadLiteral: String
        if let payload,
           let data = try? JSONSerialization.data(withJSONObject: payload),
           let s = String(data: data, encoding: .utf8) {
            payloadLiteral = s
        } else {
            payloadLiteral = "null"
        }
        run("window.mdExec && window.mdExec(\(jsString(command)), \(payloadLiteral));")
    }

    // MARK: - Callbacks from JS

    public func updateSearchResult(count: Int, index: Int) {
        matchCount = count
        currentIndex = index
    }

    // MARK: - Internals

    func run(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func jsString(_ s: String) -> String {
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
