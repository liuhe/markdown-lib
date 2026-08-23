import SwiftUI
import WebKit
import AppKit

/// WKWebView + Toast UI Editor 的 WYSIWYG markdown 编辑器。
/// 存储层还是 markdown 文本；WKWebView 侧持有富文本编辑体验。
/// 把 CSS/JS 直接内联进 HTML 再 loadHTMLString，避免 file:// 的 CORS 限制。
struct MarkdownWebEditor: NSViewRepresentable {
    @ObservedObject var store: DocumentStore
    let bridge: EditorBridge
    /// Called whenever this editor's WKWebView becomes the first responder
    /// (or the tab is otherwise reactivated). Lets the window controller
    /// point the shared search infrastructure at this tab's bridge.
    var onActivate: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "editor")

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        // 右键 → Inspect Element / Cmd+Alt+I 打开 Web Inspector
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = DropForwardingWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.dropHandler = { url in
            (NSApp.delegate as? AppDelegate)?.open(url: url)
        }
        context.coordinator.webView = webView
        bridge.webView = webView

        webView.loadHTMLString(Self.buildInlinedHTML(), baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Keep the bridge pointing at the tab's own web view — SwiftUI may
        // reuse this representable across renders and we want subsequent
        // search calls routed to the correct WKWebView.
        bridge.webView = webView
        guard context.coordinator.ready else {
            context.coordinator.pendingMarkdown = store.text
            return
        }
        context.coordinator.push(store.text, to: webView)
    }

    // MARK: - HTML 构造：内联 CSS + JS

    private static func buildInlinedHTML() -> String {
        let css = readResource("toastui-editor.min", ext: "css",
                               subdir: "Resources/toastui") ?? ""
        let js = readResource("toastui-editor-all.min", ext: "js",
                              subdir: "Resources/toastui") ?? ""
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <style>
        \(css)
        html, body { margin: 0; padding: 0; height: 100%; background: transparent; }
        #editor { height: 100%; }
        .toastui-editor-defaultUI { border: none; }
        .md-search-hit { background: rgba(255, 213, 0, 0.45); border-radius: 2px; }
        .md-search-hit-current { background: rgba(255, 149, 0, 0.75); border-radius: 2px; }
        </style>
        </head>
        <body>
        <div id="editor"></div>
        <script>
        \(js)
        </script>
        <script>
        (function () {
          var editor = new toastui.Editor({
            el: document.querySelector('#editor'),
            height: '100%',
            initialEditType: 'wysiwyg',
            previewStyle: 'tab',
            hideModeSwitch: false,
            usageStatistics: false,
            toolbarItems: [
              ['heading', 'bold', 'italic', 'strike'],
              ['hr', 'quote'],
              ['ul', 'ol', 'task'],
              ['table', 'link'],
              ['code', 'codeblock']
            ]
          });

          // 剥掉“整行只有 <br>”的行 —— Toast UI WYSIWYG 里空段落序列化成这个，
          // 但反过来解析时不生成可放光标的块，会让退格跨过整段删掉上面的列表项
          function normalizeMarkdown(md) {
            if (typeof md !== 'string') return md;
            return md.replace(/^[ \\t]*<br\\s*\\/?>[ \\t]*(\\r?\\n|$)/gim, '');
          }

          // 拿当前 WYSIWYG 编辑区的 ProseMirror 根节点
          function wwRoot() {
            return document.querySelector('.toastui-editor-ww-container .ProseMirror')
                || document.querySelector('.ProseMirror');
          }

          // 光标在编辑区文本内的字符偏移（跨节点累加 textContent 长度）
          function getCursorTextOffset() {
            var root = wwRoot();
            if (!root) return null;
            var sel = window.getSelection();
            if (!sel || !sel.rangeCount) return null;
            var range = sel.getRangeAt(0);
            if (!root.contains(range.startContainer)) return null;
            var pre = document.createRange();
            pre.selectNodeContents(root);
            pre.setEnd(range.startContainer, range.startOffset);
            return pre.toString().length;
          }

          // 按字符偏移把光标放回去；越界时钳到末尾
          function setCursorTextOffset(offset) {
            if (offset == null) return;
            var root = wwRoot();
            if (!root) return;
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
            var consumed = 0, node;
            while ((node = walker.nextNode())) {
              var len = node.textContent.length;
              if (consumed + len >= offset) {
                var r = document.createRange();
                r.setStart(node, offset - consumed);
                r.collapse(true);
                var s = window.getSelection();
                s.removeAllRanges();
                s.addRange(r);
                return;
              }
              consumed += len;
            }
            // 走到底还没匹配：贴到最末端
            var end = document.createRange();
            end.selectNodeContents(root);
            end.collapse(false);
            var s2 = window.getSelection();
            s2.removeAllRanges();
            s2.addRange(end);
          }

          var lastPushed = '';
          var suppressChange = false;
          editor.on('change', function () {
            if (suppressChange) return;
            var raw = editor.getMarkdown();
            var md = normalizeMarkdown(raw);
            // 粘贴等 mid-session mutation 会在 DOM 里塞 <br> 空段；保存干净还不够，
            // WYSIWYG DOM 里得同步清掉，否则退格照样跨过空段删列表项
            if (md !== raw) {
              var savedOffset = getCursorTextOffset();
              suppressChange = true;
              try { editor.setMarkdown(md, false); } finally { suppressChange = false; }
              // setMarkdown 是异步渲染，等 DOM 重建完再恢复光标
              setTimeout(function () { setCursorTextOffset(savedOffset); }, 0);
            }
            if (md === lastPushed) return;
            lastPushed = md;
            window.webkit.messageHandlers.editor.postMessage({ type: 'change', md: md });
            // 内容改了就清掉当前的搜索高亮，避免残留 span
            clearSearchHighlights();
          });

          window.setMarkdown = function (md) {
            if (typeof md !== 'string') return;
            md = normalizeMarkdown(md);
            if (editor.getMarkdown() === md) return;
            lastPushed = md;
            suppressChange = true;
            try { editor.setMarkdown(md, false); } finally { suppressChange = false; }
            clearSearchHighlights();
          };

          // Toast UI 输出的 URL 里 & 被写成 &amp;（HTML 实体），做一次解码
          function decodeEntities(s) {
            if (!s) return s;
            var t = document.createElement('textarea');
            t.innerHTML = s;
            return t.value;
          }

          // Cmd+click 链接 → 交给系统浏览器（不让 prosemirror 吃掉）
          document.addEventListener('click', function (e) {
            if (!e.metaKey) return;
            var a = e.target && e.target.closest ? e.target.closest('a') : null;
            if (!a || !a.href) return;
            e.preventDefault();
            e.stopPropagation();
            var url = decodeEntities(a.getAttribute('href') || a.href);
            window.webkit.messageHandlers.editor.postMessage({ type: 'openLink', url: url });
          }, true);

          function getAnchorAtCursor() {
            var sel = window.getSelection();
            if (!sel.rangeCount) return null;
            var node = sel.anchorNode;
            while (node && node !== document.body) {
              if (node.nodeType === Node.ELEMENT_NODE && node.tagName === 'A') return node;
              node = node.parentNode;
            }
            return null;
          }

          function isBlockEl(el) {
            return el && el.nodeType === Node.ELEMENT_NODE &&
                   /^(P|LI|DIV|H[1-6]|BLOCKQUOTE)$/.test(el.tagName);
          }

          function currentBlock(range) {
            var n = range.startContainer;
            if (n.nodeType !== Node.ELEMENT_NODE) n = n.parentNode;
            while (n && !isBlockEl(n)) n = n.parentNode;
            return n;
          }

          function findPopupButton(popup, labels) {
            var btns = popup.querySelectorAll('button');
            for (var i = 0; i < btns.length; i++) {
              var t = (btns[i].textContent || '').trim().toLowerCase();
              var a = (btns[i].getAttribute('aria-label') || '').trim().toLowerCase();
              for (var j = 0; j < labels.length; j++) {
                if (t === labels[j] || t.indexOf(labels[j]) !== -1 ||
                    a === labels[j] || a.indexOf(labels[j]) !== -1) {
                  return btns[i];
                }
              }
            }
            return null;
          }

          // Cmd+K：链接编辑框
          document.addEventListener('keydown', function (e) {
            if (!(e.metaKey && (e.key === 'k' || e.key === 'K'))) return;
            e.preventDefault();
            e.stopPropagation();
            var anchor = getAnchorAtCursor();
            var btn = document.querySelector('.toastui-editor-toolbar-icons.link');
            if (!btn) return;

            if (anchor) {
              // 先把整条链接文本作为当前选中，Toast UI 的 addLink 会拿它作为 linkText
              var r = document.createRange();
              r.selectNodeContents(anchor);
              var sel = window.getSelection();
              sel.removeAllRanges();
              sel.addRange(r);
            }
            btn.click();

            setTimeout(function () {
              var popup = document.querySelector('.toastui-editor-popup');
              if (!popup) return;
              var inputs = popup.querySelectorAll('input[type="text"]');

              if (anchor) {
                if (inputs[0]) {
                  inputs[0].value = decodeEntities(anchor.getAttribute('href') || anchor.href || '');
                  inputs[0].dispatchEvent(new Event('input', { bubbles: true }));
                }
                if (inputs[1]) {
                  inputs[1].value = anchor.textContent || '';
                  inputs[1].dispatchEvent(new Event('input', { bubbles: true }));
                }
              }

              // 焦点自动到 URL 输入框
              if (inputs[0]) inputs[0].focus();

              // Enter → 确认；Esc → 取消
              popup.addEventListener('keydown', function (e2) {
                if (e2.key === 'Enter') {
                  e2.preventDefault();
                  e2.stopPropagation();
                  var ok = findPopupButton(popup, ['ok', 'confirm', 'add link', 'add', 'insert']);
                  if (ok) ok.click();
                } else if (e2.key === 'Escape') {
                  e2.preventDefault();
                  e2.stopPropagation();
                  var cancel = findPopupButton(popup, ['cancel', 'close']);
                  if (cancel) {
                    cancel.click();
                  } else {
                    popup.style.display = 'none';
                  }
                  // 关掉弹框后，把焦点还给编辑器
                  try { editor.focus(); } catch (err) {}
                }
              }, true);
            }, 60);
          }, true);

          // 输入规则：`*`/`-`/`+` + 空格 → 无序列表
          // 直接操作 prosemirror view 的 state.tr.delete，用 $from.start(depth) 定位到当前
          // block 内容起点，跨节点边界之类的位置歧义就没了
          document.addEventListener('input', function (e) {
            if (e.inputType !== 'insertText' || e.data !== ' ') return;
            var sel = window.getSelection();
            if (!sel.rangeCount || !sel.isCollapsed) return;
            var block = currentBlock(sel.getRangeAt(0));
            if (!block) return;
            var text = block.textContent;
            if (text !== '* ' && text !== '- ' && text !== '+ ') return;

            try {
              var wwEditor = editor.getCurrentModeEditor();
              var view = wwEditor && wwEditor.view;
              if (view) {
                var state = view.state;
                var $from = state.selection.$from;
                // 当前 block 内容起点（不含开边界），到光标位置：把 "* " 精确覆盖
                var blockStart = $from.start($from.depth);
                var cursor = state.selection.from;
                if (blockStart < cursor) {
                  view.dispatch(state.tr.delete(blockStart, cursor));
                }
              }
              editor.exec('bulletList');
            } catch (err) {}
          }, true);

          // ---- Search / Replace --------------------------------------------------

          var searchState = { query: '', hits: [], current: -1 };

          function clearSearchHighlights() {
            var root = wwRoot();
            if (!root) return;
            var spans = root.querySelectorAll('span.md-search-hit, span.md-search-hit-current');
            for (var i = 0; i < spans.length; i++) {
              var s = spans[i];
              var parent = s.parentNode;
              while (s.firstChild) parent.insertBefore(s.firstChild, s);
              parent.removeChild(s);
              parent.normalize();
            }
            searchState = { query: '', hits: [], current: -1 };
          }

          function highlightMatches(query) {
            clearSearchHighlights();
            if (!query) {
              report();
              return;
            }
            var root = wwRoot();
            if (!root) { report(); return; }
            var q = query.toLowerCase();
            var qLen = query.length;

            // Snapshot text nodes first — mutating them while walking causes chaos.
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
              acceptNode: function (n) {
                // Skip nodes inside code blocks? No — search everywhere the user can see text.
                if (!n.nodeValue) return NodeFilter.FILTER_REJECT;
                return NodeFilter.FILTER_ACCEPT;
              }
            });
            var nodes = [];
            var n;
            while ((n = walker.nextNode())) nodes.push(n);

            var hits = [];
            for (var i = 0; i < nodes.length; i++) {
              var node = nodes[i];
              var text = node.nodeValue;
              var lower = text.toLowerCase();
              var idx = 0;
              var localHits = [];
              while (true) {
                var found = lower.indexOf(q, idx);
                if (found < 0) break;
                localHits.push(found);
                idx = found + qLen;
              }
              if (!localHits.length) continue;

              // Split the text node into runs of text + <span> highlights.
              var parent = node.parentNode;
              var cursor = 0;
              var fragment = document.createDocumentFragment();
              for (var j = 0; j < localHits.length; j++) {
                var start = localHits[j];
                if (start > cursor) {
                  fragment.appendChild(document.createTextNode(text.substring(cursor, start)));
                }
                var span = document.createElement('span');
                span.className = 'md-search-hit';
                span.appendChild(document.createTextNode(text.substr(start, qLen)));
                fragment.appendChild(span);
                hits.push(span);
                cursor = start + qLen;
              }
              if (cursor < text.length) {
                fragment.appendChild(document.createTextNode(text.substring(cursor)));
              }
              parent.replaceChild(fragment, node);
            }

            searchState = { query: query, hits: hits, current: hits.length ? 0 : -1 };
            markCurrent();
            scrollCurrentIntoView();
            report();
          }

          function markCurrent() {
            for (var i = 0; i < searchState.hits.length; i++) {
              searchState.hits[i].className = (i === searchState.current)
                ? 'md-search-hit md-search-hit-current'
                : 'md-search-hit';
            }
          }

          function scrollCurrentIntoView() {
            if (searchState.current < 0) return;
            var el = searchState.hits[searchState.current];
            if (el && el.scrollIntoView) {
              el.scrollIntoView({ block: 'center', inline: 'nearest' });
            }
          }

          function report() {
            window.webkit.messageHandlers.editor.postMessage({
              type: 'searchResult',
              count: searchState.hits.length,
              index: searchState.current + 1
            });
          }

          window.mdSearch = function (query, scrollToFirst) {
            highlightMatches(query || '');
          };

          window.mdClearSearch = function () {
            clearSearchHighlights();
            report();
          };

          window.mdFindStep = function (delta) {
            if (!searchState.hits.length) { report(); return; }
            var n = searchState.hits.length;
            searchState.current = ((searchState.current + delta) % n + n) % n;
            markCurrent();
            scrollCurrentIntoView();
            report();
          };

          // Replace / Replace All go through ProseMirror so undo history + markdown
          // serialization stay consistent.
          function pmReplaceRange(from, to, text) {
            var wwEditor = editor.getCurrentModeEditor();
            var view = wwEditor && wwEditor.view;
            if (!view) return false;
            var tr = view.state.tr.insertText(text, from, to);
            view.dispatch(tr);
            return true;
          }

          function pmDocRangeForSpan(span) {
            var wwEditor = editor.getCurrentModeEditor();
            var view = wwEditor && wwEditor.view;
            if (!view) return null;
            // The span wraps a single text node. Locate its DOM position, then map
            // to ProseMirror doc positions.
            var textNode = span.firstChild;
            if (!textNode || textNode.nodeType !== Node.TEXT_NODE) return null;
            try {
              var from = view.posAtDOM(textNode, 0);
              var to = view.posAtDOM(textNode, textNode.nodeValue.length);
              if (from == null || to == null || from < 0 || to < 0) return null;
              return { from: from, to: to };
            } catch (err) {
              return null;
            }
          }

          window.mdReplace = function (replacement) {
            if (!searchState.hits.length || searchState.current < 0) return;
            var span = searchState.hits[searchState.current];
            var range = pmDocRangeForSpan(span);
            if (!range) return;
            var q = searchState.query;
            var indexInList = searchState.current;
            pmReplaceRange(range.from, range.to, replacement || '');
            // Re-run search to rebuild the hit list, then advance to the next one.
            setTimeout(function () {
              highlightMatches(q);
              if (searchState.hits.length) {
                searchState.current = Math.min(indexInList, searchState.hits.length - 1);
                markCurrent();
                scrollCurrentIntoView();
                report();
              }
            }, 0);
          };

          window.mdReplaceAll = function (replacement) {
            if (!searchState.hits.length) return;
            var q = searchState.query;
            // Collect DOM ranges first (positions shift as we edit).
            var spans = searchState.hits.slice();
            var wwEditor = editor.getCurrentModeEditor();
            var view = wwEditor && wwEditor.view;
            if (!view) return;
            // Walk from the end so earlier ranges stay valid.
            for (var i = spans.length - 1; i >= 0; i--) {
              var range = pmDocRangeForSpan(spans[i]);
              if (!range) continue;
              var tr = view.state.tr.insertText(replacement || '', range.from, range.to);
              view.dispatch(tr);
            }
            setTimeout(function () {
              highlightMatches(q);
              report();
            }, 0);
          };

          window.webkit.messageHandlers.editor.postMessage({ type: 'ready' });
        })();
        </script>
        </body>
        </html>
        """
    }

    private static func readResource(_ name: String, ext: String, subdir: String) -> String? {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdir) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MarkdownWebEditor
        weak var webView: WKWebView?
        var ready = false
        var pendingMarkdown: String?
        var lastPushed = ""

        init(_ parent: MarkdownWebEditor) { self.parent = parent }

        // 拦截所有导航：允许初始 about: 加载；其它 URL（http/https/file）交给系统浏览器
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(decodedHTMLEntities(in: url))
            decisionHandler(.cancel)
        }

        /// 把 URL 里残留的 HTML 实体（&amp; / &lt; / &gt; / &quot; / &#39;）还原
        private func decodedHTMLEntities(in url: URL) -> URL {
            let s = url.absoluteString
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&#x27;", with: "'")
            return URL(string: s) ?? url
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let type = dict["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                parent.bridge.isEditorReady = true
                let md = pendingMarkdown ?? parent.store.text
                if let wv = webView { push(md, to: wv) }
                pendingMarkdown = nil
            case "change":
                if let md = dict["md"] as? String {
                    lastPushed = md
                    let store = parent.store
                    DispatchQueue.main.async { store.text = md }
                }
            case "openLink":
                if let s = dict["url"] as? String, let url = URL(string: s) {
                    NSWorkspace.shared.open(url)
                }
            case "searchResult":
                let count = (dict["count"] as? Int) ?? 0
                let index = (dict["index"] as? Int) ?? 0
                let bridge = parent.bridge
                DispatchQueue.main.async { bridge.updateSearchResult(count: count, index: index) }
            default: break
            }
        }

        func push(_ md: String, to webView: WKWebView) {
            guard md != lastPushed else { return }
            lastPushed = md
            let js = "window.setMarkdown(\(jsQuote(md)));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        private func jsQuote(_ s: String) -> String {
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
}

/// WKWebView subclass that forwards file-URL drops to the app delegate so they
/// open in a window instead of trying to load inside the editor.
final class DropForwardingWebView: WKWebView {
    var dropHandler: ((URL) -> Void)?

    override init(frame frameRect: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frameRect, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasMarkdownFiles(sender) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasMarkdownFiles(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }
        var handled = false
        for url in urls where isAcceptedURL(url) {
            dropHandler?(url)
            handled = true
        }
        return handled
    }

    private func hasMarkdownFiles(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }
        return urls.contains(where: isAcceptedURL)
    }

    private func isAcceptedURL(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return true
        }
        let ext = url.pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd", "txt"].contains(ext)
    }
}
