// Headless round-trip probe for the empty-paragraph serializer in
// MarkdownWebEditor.swift.
//
//   swift scripts/roundtrip-probe.swift
//
// Loads the bundled Toast UI Editor into an offscreen WKWebView, installs
// the exact `paragraph-serializer` block extracted from
// Sources/MarkdownEditor/MarkdownWebEditor.swift, then for each case:
// sets the markdown, puts the caret at the end of the first text block,
// presses Enter N times (creating empty paragraphs), serializes to
// markdown, reloads that markdown, and checks the WYSIWYG DOM and the
// markdown are identical after the second pass.
//
// Cases marked `knownLoss` are contexts the serializer deliberately
// leaves to Toast UI (nested in list items / block quotes / table cells,
// or trailing empties at the end of the document) — a FAIL there is
// expected and reported separately.

import WebKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let editorSwift = root.appendingPathComponent("Sources/MarkdownEditor/MarkdownWebEditor.swift")
let toastJS = root.appendingPathComponent("Sources/MarkdownEditor/Resources/toastui/toastui-editor-all.min.js")

let js = try! String(contentsOf: toastJS, encoding: .utf8)
let swiftSource = try! String(contentsOf: editorSwift, encoding: .utf8)

// Pull the serializer out of the Swift string literal and undo the
// literal's backslash escaping so it's plain JS again.
func extractSerializer() -> String {
    guard let start = swiftSource.range(of: "// BEGIN paragraph-serializer"),
          let end = swiftSource.range(of: "// END paragraph-serializer") else {
        fatalError("paragraph-serializer markers not found in MarkdownWebEditor.swift")
    }
    return String(swiftSource[start.lowerBound..<end.upperBound])
        .replacingOccurrences(of: "\\\\", with: "\\")
}

struct Case { let md: String; let enters: Int; let knownLoss: Bool }
func c(_ md: String, _ enters: Int, knownLoss: Bool = false) -> Case { Case(md: md, enters: enters, knownLoss: knownLoss) }

let cases: [Case] = [
    // The original bug report: blank line between two task items.
    c("- [ ] a\n- [ ] b\n", 2), c("- [ ] a\n- [ ] b\n", 3), c("- [ ] a\n- [ ] b\n", 4),
    c("- a\n- b\n", 2), c("1. a\n2. b\n", 2), c("3. a\n4. b\n", 2),
    // list → other blocks
    c("- [ ] a\n\n# H\n", 2), c("- [ ] a\n\n---\n", 2), c("- [ ] a\n\n---\n", 3),
    c("- [ ] a\n\n2. x\n", 2), c("- [ ] a\n\n> q\n", 2),
    c("- [ ] a\n\n```\ncode\n```\n", 2),
    c("- [ ] a\n\n| a | b |\n|---|---|\n| 1 | 2 |\n", 2),
    c("- [ ] a\n\npara\n", 2), c("- [ ] a\n\npara\n", 3),
    // paragraph → other blocks
    c("para\n- [ ] b\n", 2), c("para\n\n- [ ] b\n", 1), c("para\n\n- [ ] b\n", 2), c("para\n\n- [ ] b\n", 3),
    c("para\n\n1. b\n", 1), c("para\n\n2. b\n", 1), c("para\n\n2. b\n", 2),
    c("para\n\n# H\n", 1), c("para\n\n---\n", 1), c("para\n\n---\n", 2),
    c("para\n\n> q\n", 1), c("para\n\n| a | b |\n|---|---|\n| 1 | 2 |\n", 1),
    c("para\n\n```\ncode\n```\n", 1),
    // paragraph → paragraph (Toast UI's own blank-line encoding)
    c("para\npara2\n", 1), c("para\npara2\n", 2), c("para\npara2\n", 3),
    c("para\n\npara2\n", 1), c("para\n\npara2\n", 2),
    // heading → others
    c("# H\n\npara\n", 1), c("# H\n\npara\n", 2), c("# H\n\n- [ ] b\n", 1), c("# H\n\n## H2\n", 1),
    // nested lists
    c("- a\n  - b\n  - c\n", 2),
    // Left to Toast UI: nested contexts and trailing empties.
    c("| a | b |\n|---|---|\n| 1 | 2 |\n\npara\n", 1, knownLoss: true),
    c("```\ncode\n```\n\npara\n", 1, knownLoss: true),
    c("---\n\npara\n", 1, knownLoss: true),
    c("> q\n\npara\n", 1, knownLoss: true),
    c("- [ ] a\n\n  x\n- [ ] b\n", 1, knownLoss: true),
    c("> q\n> r\n", 2, knownLoss: true),
    c("para\n", 1, knownLoss: true),
    c("- [ ] a\n", 2, knownLoss: true),
]

let html = """
<!DOCTYPE html><html><head><meta charset="UTF-8"></head><body><div id="editor"></div>
<script>\(js)</script>
<script>
var editor = new toastui.Editor({ el: document.querySelector('#editor'), initialEditType: 'wysiwyg', usageStatistics: false });
\(extractSerializer())
function ww() { return document.querySelector('.toastui-editor-ww-container .ProseMirror'); }
function norm(h) {
  return h.replace(/ class="ProseMirror-trailingBreak"/g, '')
          .replace(/ class="task-list-item" data-task="true"/g, '');
}
function sim(md, enters) {
  editor.setMarkdown(md, false);
  var view = editor.getCurrentModeEditor().view;
  var st = view.state;
  var pos = null;
  st.doc.descendants(function (n, p) {
    if (pos == null && n.isTextblock) pos = p + 1 + n.content.size;
    return pos == null;
  });
  view.dispatch(st.tr.setSelection(st.selection.constructor.near(st.doc.resolve(pos))));
  for (var i = 0; i < enters; i++) {
    view.dom.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true
    }));
  }
  return { dom: norm(ww().innerHTML), out: editor.getMarkdown() };
}
window.roundtrip = function (md, enters) {
  var r1 = sim(md, enters);
  editor.setMarkdown(r1.out, false);
  var dom2 = norm(ww().innerHTML), out2 = editor.getMarkdown();
  return JSON.stringify({ out: r1.out, ok: r1.dom === dom2 && r1.out === out2,
                          dom1: r1.dom, dom2: dom2, out2: out2 });
};
</script></body></html>
"""

final class Driver: NSObject, WKNavigationDelegate {
    var failures = 0
    var unexpectedFailures = 0
    func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        func run(_ i: Int) {
            if i >= cases.count {
                print("\n\(cases.count) cases, \(failures) failed, \(unexpectedFailures) unexpected")
                exit(unexpectedFailures == 0 ? 0 : 1)
            }
            let k = cases[i]
            let q = String(data: try! JSONSerialization.data(withJSONObject: [k.md]), encoding: .utf8)!
            wv.evaluateJavaScript("roundtrip(\(q)[0], \(k.enters))") { r, e in
                guard let s = r as? String,
                      let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
                    print("ERR  \(k.md.debugDescription) enters=\(k.enters): \(e.map(String.init(describing:)) ?? "no result")")
                    self.failures += 1; self.unexpectedFailures += 1
                    run(i + 1); return
                }
                let ok = d["ok"] as? Bool ?? false
                let tag = ok ? "OK  " : (k.knownLoss ? "LOSS" : "FAIL")
                print("\(tag) \(k.md.debugDescription) enters=\(k.enters) -> \((d["out"] as? String ?? "").debugDescription)")
                if !ok {
                    self.failures += 1
                    if !k.knownLoss {
                        self.unexpectedFailures += 1
                        print("     dom1: \(d["dom1"] ?? "")\n     dom2: \(d["dom2"] ?? "")\n     out2: \((d["out2"] as? String ?? "").debugDescription)")
                    }
                }
                run(i + 1)
            }
        }
        run(0)
    }
}

let driver = Driver()
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
webView.navigationDelegate = driver
webView.loadHTMLString(html, baseURL: nil)
RunLoop.main.run()
