import SwiftUI
import WebKit

/// WKWebView + Toast UI Editor 的 WYSIWYG markdown 编辑器。
/// 存储层还是 markdown 文本；WKWebView 侧持有富文本编辑体验。
/// 把 CSS/JS 直接内联进 HTML 再 loadHTMLString，避免 file:// 的 CORS 限制。
struct MarkdownWebEditor: NSViewRepresentable {
    @Binding var markdown: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "editor")

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        // 右键 → Inspect Element / Cmd+Alt+I 打开 Web Inspector
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        webView.loadHTMLString(Self.buildInlinedHTML(), baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.ready else {
            context.coordinator.pendingMarkdown = markdown
            return
        }
        context.coordinator.push(markdown, to: webView)
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

          // 剥掉"整行只有 <br>"的行 —— Toast UI WYSIWYG 里空段落序列化成这个，
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
          });

          window.setMarkdown = function (md) {
            if (typeof md !== 'string') return;
            md = normalizeMarkdown(md);
            if (editor.getMarkdown() === md) return;
            lastPushed = md;
            suppressChange = true;
            try { editor.setMarkdown(md, false); } finally { suppressChange = false; }
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
                let md = pendingMarkdown ?? parent.markdown
                if let wv = webView { push(md, to: wv) }
                pendingMarkdown = nil
            case "change":
                if let md = dict["md"] as? String {
                    lastPushed = md
                    DispatchQueue.main.async { self.parent.markdown = md }
                }
            case "openLink":
                if let s = dict["url"] as? String, let url = URL(string: s) {
                    NSWorkspace.shared.open(url)
                }
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
