import SwiftUI
import WebKit
import AppKit

/// WKWebView + Toast UI Editor WYSIWYG markdown editor.
///
/// The underlying storage stays as markdown text; the WKWebView provides
/// the rich-text editing surface. CSS/JS are inlined into the HTML and
/// handed to `loadHTMLString` so we sidestep `file://` CORS.
///
/// Host apps get callbacks via `bridge.onOpenLink` / `onDropURL` /
/// `onPasteImage`; the editor never reaches into `NSApp.delegate` or
/// anywhere else app-specific.
public struct MarkdownWebEditor: NSViewRepresentable {
    @ObservedObject public var store: DocumentStore
    public let bridge: EditorBridge

    public init(store: DocumentStore, bridge: EditorBridge) {
        self.store = store
        self.bridge = bridge
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "editor")

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        // Right-click → Inspect Element / Cmd+Alt+I opens the Web Inspector.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = DropForwardingWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        let bridge = self.bridge
        webView.dropHandler = { [weak bridge] url in
            bridge?.onDropURL?(url)
        }
        context.coordinator.webView = webView
        bridge.webView = webView

        webView.loadHTMLString(Self.buildInlinedHTML(), baseURL: nil)
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
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
        let mermaidJS = readResource("mermaid.min", ext: "js",
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
        .mermaid-block { display: block; margin: 12px 0; padding: 8px;
                         background: rgba(0,0,0,0.02); border-radius: 4px;
                         text-align: center; overflow: auto; }
        .mermaid-block svg { max-width: 100%; height: auto; }
        .mermaid-error { color: #b00020; font-family: monospace; text-align: left;
                         white-space: pre-wrap; }
        </style>
        </head>
        <body spellcheck="false" autocorrect="off" autocapitalize="off" translate="no">
        <div id="editor"></div>
        <script>
        \(js)
        </script>
        <script>
        \(mermaidJS)
        </script>
        <script>
        (function () {
          if (window.mermaid && typeof window.mermaid.initialize === 'function') {
            try {
              window.mermaid.initialize({
                startOnLoad: false,
                securityLevel: 'loose',
                theme: 'default'
              });
            } catch (err) { /* ignore init errors */ }
          }

          // Toast UI codeBlock → mermaid renderer: emits <div class="mermaid-block">
          // with the raw source text; runMermaid() below swaps innerHTML with SVG.
          var mermaidRenderer = {
            codeBlock: function (node) {
              var info = (node.info || '').trim().toLowerCase();
              if (info === 'mermaid') {
                return [
                  { type: 'openTag', tagName: 'div',
                    classNames: ['mermaid-block'],
                    outerNewLine: true },
                  { type: 'text', content: node.literal || '' },
                  { type: 'closeTag', tagName: 'div', outerNewLine: true }
                ];
              }
              return null;
            }
          };

          var editor = new toastui.Editor({
            el: document.querySelector('#editor'),
            height: '100%',
            initialEditType: 'wysiwyg',
            previewStyle: 'vertical',
            hideModeSwitch: false,
            usageStatistics: false,
            toolbarItems: [
              ['heading', 'bold', 'italic', 'strike'],
              ['hr', 'quote'],
              ['ul', 'ol', 'task'],
              ['table', 'link'],
              ['code', 'codeblock']
            ],
            customHTMLRenderer: mermaidRenderer,
            // Intercept image drops / pastes: hand the blob to Swift, which
            // writes it to `<basename>.assets/paste-…` next to the current
            // file and hands us back a relative-path URL to insert.
            hooks: {
              addImageBlobHook: function (blob, callback) {
                handleImageBlob(blob, callback);
              }
            }
          });

          // Render every unrendered <div class="mermaid-block"> in the DOM.
          // The customHTMLRenderer emits them with source as textContent; on
          // each preview refresh the divs are recreated, so we don't need to
          // track staleness — just process anything not yet marked done.
          var mermaidSeq = 0;
          function runMermaid() {
            if (!window.mermaid) return;
            var blocks = document.querySelectorAll('.mermaid-block:not([data-mermaid-done])');
            for (var i = 0; i < blocks.length; i++) {
              (function (el) {
                var source = el.textContent || '';
                el.setAttribute('data-mermaid-done', '1');
                var id = 'mermaid-' + (++mermaidSeq);
                try {
                  var p = window.mermaid.render(id, source);
                  if (p && typeof p.then === 'function') {
                    p.then(function (result) { el.innerHTML = result.svg; })
                     .catch(function (err) {
                       el.innerHTML = '<pre class="mermaid-error">' +
                         String(err && err.message || err) + '</pre>';
                     });
                  } else if (p && p.svg) {
                    el.innerHTML = p.svg;
                  }
                } catch (err) {
                  el.innerHTML = '<pre class="mermaid-error">' +
                    String(err && err.message || err) + '</pre>';
                }
              })(blocks[i]);
            }
          }
          var mermaidTimer = null;
          function scheduleMermaid() {
            if (mermaidTimer) clearTimeout(mermaidTimer);
            mermaidTimer = setTimeout(runMermaid, 120);
          }

          var pendingImagePastes = {};
          var pastesCounter = 0;

          function handleImageBlob(blob, callback) {
            if (!blob) { callback('', ''); return; }
            var reader = new FileReader();
            reader.onload = function () {
              var dataUrl = String(reader.result || '');
              var comma = dataUrl.indexOf(',');
              if (comma < 0) { callback('', ''); return; }
              var base64 = dataUrl.substring(comma + 1);
              var mime = blob.type || 'image/png';
              var id = 'p' + (++pastesCounter);
              pendingImagePastes[id] = callback;
              window.webkit.messageHandlers.editor.postMessage({
                type: 'pasteImage',
                id: id,
                base64: base64,
                mime: mime
              });
            };
            reader.onerror = function () { callback('', ''); };
            reader.readAsDataURL(blob);
          }

          window.mdImagePasteResult = function (id, href, alt) {
            var cb = pendingImagePastes[id];
            if (!cb) return;
            delete pendingImagePastes[id];
            cb(href || '', alt || '');
          };

          // Kill spellcheck / autocorrect / smart-substitution on every
          // contenteditable ProseMirror creates. WKWebView's spellcheck
          // path (applespell) hitches the input queue on longer docs.
          //
          // Body-level `spellcheck="false"` in the HTML template is inherited
          // by descendants per the HTML spec, so we only need to sweep once
          // after the editor initializes to cover any element ProseMirror
          // set up before the observer would have caught it. Do NOT install
          // a persistent MutationObserver here — an `attributes: true`
          // subtree observer burned notable idle CPU because ProseMirror
          // mutates selection-widget attributes continuously.
          function disableSpellCheckOn(el) {
            if (!el) return;
            el.setAttribute('spellcheck', 'false');
            el.setAttribute('autocorrect', 'off');
            el.setAttribute('autocapitalize', 'off');
            el.setAttribute('translate', 'no');
          }
          function disableSpellCheckEverywhere() {
            var nodes = document.querySelectorAll('[contenteditable]');
            for (var i = 0; i < nodes.length; i++) disableSpellCheckOn(nodes[i]);
          }
          setTimeout(disableSpellCheckEverywhere, 0);
          setTimeout(disableSpellCheckEverywhere, 250);
          setTimeout(disableSpellCheckEverywhere, 1000);

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
            // Normalize on the *outbound* markdown only — DO NOT feed the
            // normalized copy back into the editor via setMarkdown. Doing so
            // rebuilds the DOM and wipes any empty paragraph the user just
            // created by pressing Enter (Toast UI serializes empty <p><br></p>
            // as a bare "<br>" line, which normalizeMarkdown strips).
            //
            // Trade-off: if the "backspace-after-paste eats a list item"
            // bug that used to be fixed here resurfaces, handle it in a more
            // targeted spot (paste event or an explicit Backspace keydown
            // interceptor) instead of on every change.
            var md = normalizeMarkdown(raw);
            if (md === lastPushed) return;
            lastPushed = md;
            window.webkit.messageHandlers.editor.postMessage({ type: 'change', md: md });
            // 内容改了就清掉当前的搜索高亮，避免残留 span
            clearSearchHighlights();
            scheduleMermaid();
          });

          window.setMarkdown = function (md) {
            if (typeof md !== 'string') return;
            md = normalizeMarkdown(md);
            if (editor.getMarkdown() === md) return;
            lastPushed = md;
            suppressChange = true;
            try { editor.setMarkdown(md, false); } finally { suppressChange = false; }
            clearSearchHighlights();
            scheduleMermaid();
          };

          // Toast UI 输出的 URL 里 & 被写成 &amp;（HTML 实体），做一次解码
          function decodeEntities(s) {
            if (!s) return s;
            var t = document.createElement('textarea');
            t.innerHTML = s;
            return t.value;
          }

          // Cmd+click on a link → open externally / in a tab.
          // Cmd+click on an inline `code` span whose text looks like a
          // markdown path (`../foo.md`, `notes/index.md`, `foo.md#anchor`,
          // …) → same. We DO NOT rewrite the file — the backticks stay in
          // the markdown on disk. This is purely a navigation aid at
          // view/edit time.
          function looksLikeMarkdownPath(text) {
            if (!text) return false;
            var t = text.trim();
            if (!t || t.length > 512) return false;
            if (t.indexOf('\\n') !== -1) return false;
            return /\\.(md|markdown|mdown|mkd)(#.*)?$/i.test(t);
          }

          document.addEventListener('click', function (e) {
            if (!e.metaKey) return;
            var target = e.target && e.target.closest ? e.target : null;
            if (!target) return;

            var a = target.closest('a');
            if (a && a.href) {
              e.preventDefault();
              e.stopPropagation();
              var url = decodeEntities(a.getAttribute('href') || a.href);
              window.webkit.messageHandlers.editor.postMessage({ type: 'openLink', url: url });
              return;
            }

            var code = target.closest('code');
            if (code) {
              var text = code.textContent || '';
              if (looksLikeMarkdownPath(text)) {
                e.preventDefault();
                e.stopPropagation();
                window.webkit.messageHandlers.editor.postMessage({
                  type: 'openLink',
                  url: text.trim()
                });
              }
            }
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

          // Cmd+Shift+K: ask the Swift side to open a workspace file picker.
          // We ship the current selection along as the default link label.
          document.addEventListener('keydown', function (e) {
            if (!(e.metaKey && e.shiftKey && (e.key === 'k' || e.key === 'K'))) return;
            e.preventDefault();
            e.stopPropagation();
            requestFileLink();
          }, true);

          function requestFileLink() {
            var sel = window.getSelection();
            var text = '';
            try {
              if (sel && !sel.isCollapsed && wwRoot() && wwRoot().contains(sel.anchorNode)) {
                text = sel.toString();
              }
            } catch (err) {}
            window.webkit.messageHandlers.editor.postMessage({
              type: 'pickFileLink',
              selection: text
            });
          }
          // Exposed for the native menu path (Edit → Insert Link to File…).
          window.mdRequestFileLink = requestFileLink;

          // Programmatic link insertion invoked by Swift once the user has
          // picked a target file. `text` is the label to render; `href` is
          // the relative path. If there's a selection, replace it with the
          // labelled link; otherwise insert at the cursor.
          window.mdInsertLink = function (href, text) {
            var wwEditor = editor.getCurrentModeEditor();
            var view = wwEditor && wwEditor.view;
            if (!view || !href) return;
            var state = view.state;
            var linkMark = state.schema.marks.link;
            if (!linkMark) return;

            var from = state.selection.from;
            var to = state.selection.to;
            var label = (text && text.length) ? text : href;

            // Toast UI's link mark stores href on `linkUrl` (its extension of
            // ProseMirror's default), and titles on `title`. Set both defensively.
            var attrs = { linkUrl: href, href: href, title: null };
            var mark = linkMark.create(attrs);

            var tr;
            if (from === to) {
              // Nothing selected: insert `label` and mark it.
              tr = state.tr.insertText(label, from);
              tr = tr.addMark(from, from + label.length, mark);
            } else {
              // Something selected. If the caller supplied text that differs
              // from the selection, replace it; otherwise just mark the range.
              var selected = state.doc.textBetween(from, to);
              if (text && text.length && text !== selected) {
                tr = state.tr.insertText(text, from, to);
                tr = tr.addMark(from, from + text.length, mark);
              } else {
                tr = state.tr.addMark(from, to, mark);
              }
            }
            view.dispatch(tr);
            try { editor.focus(); } catch (err) {}
          };

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

          // Enter inside a completed task item: the split preserves attrs on
          // both halves, so the new item ends up checked too. Reset it —
          // the caret ends up inside the new item, so we just look at
          // `checked` under the current selection after the default Enter
          // handling has run.
          document.addEventListener('keydown', function (e) {
            if (e.key !== 'Enter') return;
            if (e.metaKey || e.ctrlKey || e.altKey) return;
            setTimeout(function () {
              try {
                var wwEditor = editor.getCurrentModeEditor();
                var view = wwEditor && wwEditor.view;
                if (!view) return;
                var state = view.state;
                var taskType = state.schema.nodes.taskItem;
                if (!taskType) return;
                var $from = state.selection.$from;
                var depth = $from.depth;
                while (depth > 0 && $from.node(depth).type !== taskType) {
                  depth--;
                }
                if (depth <= 0) return;
                var node = $from.node(depth);
                if (!node.attrs || !node.attrs.checked) return;
                var pos = $from.before(depth);
                var attrs = Object.assign({}, node.attrs, { checked: false });
                view.dispatch(state.tr.setNodeMarkup(pos, null, attrs));
              } catch (err) {}
            }, 0);
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

          // Thin wrapper over Toast UI Editor's `exec(command, payload)`
          // called by the native Format menu (⌘B / ⌘I / heading levels /
          // list types / …). Payload is JSON-serialisable from Swift; we
          // pass it through unchanged.
          window.mdExec = function (command, payload) {
            try {
              if (payload && typeof payload === 'object') {
                editor.exec(command, payload);
              } else {
                editor.exec(command);
              }
              editor.focus();
            } catch (err) {}
          };

          // Scroll the Nth heading (ATX h1..h6) in document order into view.
          // Matching by index (rather than by text) is stable when heading
          // text repeats.
          window.mdScrollToHeading = function (index) {
            var root = wwRoot();
            if (!root) return;
            var headings = root.querySelectorAll('h1, h2, h3, h4, h5, h6');
            if (index < 0 || index >= headings.length) return;
            headings[index].scrollIntoView({ behavior: 'smooth', block: 'start' });
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

    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MarkdownWebEditor
        weak var webView: WKWebView?
        var ready = false
        var pendingMarkdown: String?
        var lastPushed = ""

        init(_ parent: MarkdownWebEditor) { self.parent = parent }

        // Intercept every navigation: allow the initial `about:` load; any
        // other URL (http/https/file) routes through `openLinkedHref`.
        public func webView(_ webView: WKWebView,
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
            // If the navigation somehow slips past the JS Cmd+click handler,
            // route it through the same path so file:// links land in a tab
            // and http/https go to the browser. Never blindly pass to
            // Launch Services — a naked relative href (no scheme) crashes
            // with `-50 The application can't be opened.`
            openLinkedHref(url.absoluteString)
            decisionHandler(.cancel)
        }

        /// Resolve a link `href` (as delivered by the JS side) into an
        /// absolute URL and hand it to `bridge.onOpenLink` when the host
        /// wired one up. Falls back to `NSWorkspace` for non-`file://`
        /// URLs when the host didn't supply a handler; `file://` URLs are
        /// dropped in that case (the host is expected to know what to do
        /// with them — e.g., open as a tab).
        ///
        /// Handles both percent-encoded relative paths (`../ideas%20.md`)
        /// and raw ones (`../ideas .md`), falling back through both parsing
        /// strategies before giving up.
        fileprivate func openLinkedHref(_ raw: String) {
            let href = decodedHTMLEntitiesString(raw)
            // Fragment-only link (e.g., `#some-heading`): nothing meaningful
            // to open — beep so the user knows it registered.
            if href.hasPrefix("#") { NSSound.beep(); return }

            // Absolute URL with a scheme: dispatch by scheme.
            if let url = URL(string: href), let scheme = url.scheme, !scheme.isEmpty {
                deliverLink(url)
                return
            }

            // Relative path: try resolving against the current file first
            // (classic markdown), then against the workspace root (so a
            // backticked `notes/index.md` in the text opens even when the
            // author wrote it root-relative). We pick the first candidate
            // that actually exists on disk; if none exist, fall back to the
            // classic-relative interpretation so the host's missing-file
            // alert (if any) makes sense.
            let candidates = candidateFileURLs(for: href)
            for url in candidates where FileManager.default.fileExists(atPath: url.path) {
                deliverLink(url)
                return
            }
            if let first = candidates.first {
                deliverLink(first)
            } else {
                NSSound.beep()
            }
        }

        /// Hand `url` off to the host, or fall back to `NSWorkspace` for
        /// non-file URLs when the host didn't set a handler.
        private func deliverLink(_ url: URL) {
            if let handler = parent.bridge.onOpenLink {
                handler(url.isFileURL ? url.standardizedFileURL : url)
            } else if !url.isFileURL {
                NSWorkspace.shared.open(url)
            }
            // No fallback for file URLs — a host without a handler has no
            // opinion on tab routing, so we just do nothing.
        }

        /// Ordered list of file URLs to try for a relative `href`:
        ///   1. Resolved against the current document's directory.
        ///   2. Resolved against the workspace root, when there is one and
        ///      the href isn't already navigating out (`./`, `../`).
        private func candidateFileURLs(for href: String) -> [URL] {
            var out: [URL] = []
            if let base = parent.store.fileURL,
               let u = Self.resolveRelative(href: href, base: base) {
                out.append(u)
            }
            if let root = parent.bridge.workspaceRootURL,
               !href.hasPrefix("./"),
               !href.hasPrefix("../"),
               let u = Self.resolveRelativeToRoot(href: href, root: root) {
                if !out.contains(u) { out.append(u) }
            }
            return out
        }

        /// Try two strategies: first as a URL-encoded relative reference
        /// (handles `%20` &c.), then as a raw filesystem path if the first
        /// parse produced nothing usable.
        private static func resolveRelative(href: String, base: URL) -> URL? {
            if let url = URL(string: href, relativeTo: base) {
                let abs = url.absoluteURL.standardizedFileURL
                if abs.isFileURL { return abs }
            }
            let baseDir = base.deletingLastPathComponent()
            let decoded = href.removingPercentEncoding ?? href
            return URL(fileURLWithPath: decoded, relativeTo: baseDir)
                .absoluteURL
                .standardizedFileURL
        }

        /// Resolve `href` as a workspace-root-relative path. Strips a
        /// leading `/` so `/notes/foo.md` and `notes/foo.md` both work.
        private static func resolveRelativeToRoot(href: String, root: URL) -> URL? {
            let stripped = href.hasPrefix("/") ? String(href.dropFirst()) : href
            let decoded = stripped.removingPercentEncoding ?? stripped
            return URL(fileURLWithPath: decoded, relativeTo: root)
                .absoluteURL
                .standardizedFileURL
        }

        private func decodedHTMLEntitiesString(_ s: String) -> String {
            s.replacingOccurrences(of: "&amp;", with: "&")
             .replacingOccurrences(of: "&lt;", with: "<")
             .replacingOccurrences(of: "&gt;", with: ">")
             .replacingOccurrences(of: "&quot;", with: "\"")
             .replacingOccurrences(of: "&#39;", with: "'")
             .replacingOccurrences(of: "&#x27;", with: "'")
        }

        public func userContentController(_ userContentController: WKUserContentController,
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
                    DispatchQueue.main.async {
                        PerfLog.measure("DocumentStore.text = md (\(md.utf8.count) B)") {
                            store.text = md
                        }
                    }
                }
            case "openLink":
                if let s = dict["url"] as? String {
                    openLinkedHref(s)
                }
            case "searchResult":
                let count = (dict["count"] as? Int) ?? 0
                let index = (dict["index"] as? Int) ?? 0
                let bridge = parent.bridge
                DispatchQueue.main.async { bridge.updateSearchResult(count: count, index: index) }
            case "pickFileLink":
                let selection = dict["selection"] as? String
                let bridge = parent.bridge
                DispatchQueue.main.async {
                    bridge.onFileLinkPickerRequested?(selection?.isEmpty == true ? nil : selection)
                }
            case "pasteImage":
                guard let id = dict["id"] as? String,
                      let base64 = dict["base64"] as? String else { break }
                let mime = (dict["mime"] as? String) ?? "image/png"
                DispatchQueue.main.async { self.handleImagePaste(id: id, base64: base64, mime: mime) }
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

        // MARK: - Paste image

        /// Route a pasted / dropped image blob through
        /// `bridge.onPasteImage` (host decides where to save it), then hand
        /// back a document-relative URL so Toast UI Editor can insert
        /// `![](rel/path.ext)`. When there's no host handler, the paste is
        /// rejected — the library itself has no opinion on where images
        /// belong.
        fileprivate func handleImagePaste(id: String, base64: String, mime: String) {
            guard let data = Data(base64Encoded: base64), !data.isEmpty else {
                respondImagePaste(id: id, href: "", alt: "")
                return
            }
            guard let handler = parent.bridge.onPasteImage else {
                respondImagePaste(id: id, href: "", alt: "")
                return
            }
            guard let savedURL = handler(data, mime) else {
                respondImagePaste(id: id, href: "", alt: "")
                return
            }
            // Relativize against the current file when we have one, so the
            // markdown source stays portable. Untitled tab → best we can do
            // is a `file://` absolute link.
            let href: String
            if let sourceURL = parent.store.fileURL {
                href = RelativePath.relative(from: sourceURL, to: savedURL)
            } else {
                href = savedURL.absoluteString
            }
            respondImagePaste(id: id, href: href, alt: "")
        }

        private func respondImagePaste(id: String, href: String, alt: String) {
            let js = "window.mdImagePasteResult && window.mdImagePasteResult(\(jsQuote(id)), \(jsQuote(href)), \(jsQuote(alt)));"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

    }

    /// Best-effort map from an image MIME type to a filename extension.
    /// Exposed publicly so a host's `bridge.onPasteImage` closure can pick
    /// a sane extension without reimplementing the table.
    public static func extensionForMIME(_ mime: String) -> String {
        switch mime.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        case "image/heic": return "heic"
        case "image/tiff": return "tiff"
        case "image/bmp": return "bmp"
        default:
            if let slash = mime.firstIndex(of: "/") {
                let raw = String(mime[mime.index(after: slash)...])
                    .split(separator: "+").first.map(String.init) ?? ""
                return raw.isEmpty ? "png" : raw
            }
            return "png"
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
