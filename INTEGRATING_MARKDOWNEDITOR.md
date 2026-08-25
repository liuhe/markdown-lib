# Integrating MarkdownEditor

This document is for apps that want to embed the reusable `MarkdownEditor`
library product without adopting the full `markdown-lib` app shell.

`MarkdownEditor` provides the editor surface and document primitives. Your host
app remains responsible for windows, tabs, menus, persistence UI, workspace UI,
and app-specific routing.

## Add the package

```swift
.package(url: "https://github.com/liuhe/markdown-lib.git", from: "0.15.0")
```

Then depend on the library product:

```swift
.product(name: "MarkdownEditor", package: "markdown-lib")
```

Requirements match the package: macOS 14+ and Swift 5.9+.

## Minimal integration

```swift
import SwiftUI
import AppKit
import MarkdownEditor

struct MyMarkdownEditor: View {
    @StateObject private var store = DocumentStore()
    @StateObject private var bridge = EditorBridge()

    var body: some View {
        MarkdownWebEditor(store: store, bridge: bridge)
            .onAppear {
                bridge.onOpenLink = { url in
                    NSWorkspace.shared.open(url)
                }
                bridge.onDropURL = { url in
                    // Decide whether to open the dropped file/folder.
                }
                bridge.onPasteImage = { data, mime in
                    // Save the image and return its on-disk URL.
                    nil
                }
                bridge.onFileLinkPickerRequested = { selectedText in
                    // Present your own file picker, then call
                    // bridge.insertLink(href:text:).
                }
            }
    }
}
```

For a file-backed document:

```swift
let store = DocumentStore()
try store.read(from: url)

// Later:
try store.save()
// or Save As:
try store.write(to: newURL)
```

## What the library includes

The library exports:

- `MarkdownWebEditor`: SwiftUI `NSViewRepresentable` wrapping a WKWebView and
  Toast UI Editor.
- `DocumentStore`: observable document state, file I/O, dirty tracking,
  frontmatter preservation, and external modification detection.
- `EditorBridge`: imperative editor API plus callbacks for host-owned side
  effects.
- `FindBar`: find/replace UI driven by an `EditorBridge`.
- `MarkdownOutline` and `OutlineView`: ATX heading parsing and outline UI.
- `Frontmatter`: raw YAML-frontmatter split/assemble/title helpers.
- `RelativePath`: file-to-file relative URL helper.
- `PerfLog`: optional performance logging utilities.

The library does **not** include the full app shell: windows, native tabs,
workspace sidebar, recents, app menus, save dialogs, close/quit confirmation, or
fuzzy file picker.

## Document model and metadata

`DocumentStore.text` is the markdown body only. If the file begins with YAML
frontmatter, `DocumentStore.read(from:)` strips the leading `--- ... ---` block
and stores it separately in `rawFrontmatter`.

Important rules:

- Unknown frontmatter keys are preserved verbatim on save.
- The library only understands one key today: top-level `title:`.
- `DocumentStore.title` reads `title:` from `rawFrontmatter`.
- `DocumentStore.displayName` prefers `title`, then filename, then `Untitled`.
- To change metadata, call `store.setFrontmatter(...)`; do not mutate
  `rawFrontmatter` directly.
- To serialize a full document yourself, use
  `Frontmatter.assemble(frontmatter:body:)`.

Recommended metadata pattern:

```swift
let newFrontmatter = Frontmatter.settingTitle("My Title", in: store.rawFrontmatter)
store.setFrontmatter(newFrontmatter)
```

If your app owns additional metadata such as `tags`, `aliases`, `date`, or
custom nested maps, prefer small targeted reads/writes that preserve unrelated
lines. Avoid parsing and re-serializing the whole YAML block unless you are
comfortable owning ordering, comments, quoting, and unknown schemas.

## Saving, dirty state, and external edits

`DocumentStore.isDirty` is true when either the body changed or frontmatter was
changed through `setFrontmatter(...)`.

Recommended host behavior:

- Use `store.isDirty` to drive edited indicators and close/quit prompts.
- Use `store.fileURL == nil` to decide whether Save should become Save As.
- Call `try store.save()` for normal Save.
- Call `try store.write(to:)` for Save As.
- Watch `store.externallyModified` and present your own Reload / Keep Editing
  prompt.
- Use `store.revertFromDisk()` to reload and discard in-memory changes.
- Use `store.dismissExternalModification()` if the user chooses to keep editing.

The library polls the backing file for external modifications. It also debounces
its own writes so normal saves do not immediately trigger an external-edit
warning.

## Image paste and drop handling

The editor intercepts pasted or dropped image blobs and forwards them to:

```swift
bridge.onPasteImage: (Data, String) -> URL?
```

The closure receives image bytes and a MIME type. The host decides where to save
the file and returns the saved on-disk URL. The library then inserts markdown:

```markdown
![](relative/path.ext)
```

If `store.fileURL` is set, the inserted URL is relative to the markdown file. If
the document is untitled, the library can only insert an absolute `file://` URL.
For portable markdown, the recommended behavior is to reject image paste until
the document has been saved.

Recommended `markdown-lib`-compatible policy:

- Require the markdown document to have a saved `fileURL` first.
- Store pasted images next to the markdown file in:

  ```text
  <basename>.assets/paste-yyyymmdd-HHmmss.ext
  ```

- Use `MarkdownWebEditor.extensionForMIME(_:)` to choose the extension.
- On filename collision, append `-2`, `-3`, etc.
- Write atomically.
- Return `nil` to reject the paste if the save fails or the document is untitled.

Example:

```swift
bridge.onPasteImage = { data, mime in
    guard let sourceURL = store.fileURL else {
        return nil
    }

    let assetsDir = sourceURL
        .deletingPathExtension()
        .appendingPathExtension("assets")

    try? FileManager.default.createDirectory(
        at: assetsDir,
        withIntermediateDirectories: true
    )

    let ext = MarkdownWebEditor.extensionForMIME(mime)
    let stamp = Self.imagePasteStamp()
    var target = assetsDir.appendingPathComponent("paste-\(stamp).\(ext)")
    var i = 2

    while FileManager.default.fileExists(atPath: target.path) {
        target = assetsDir.appendingPathComponent("paste-\(stamp)-\(i).\(ext)")
        i += 1
    }

    do {
        try data.write(to: target, options: .atomic)
        return target
    } catch {
        return nil
    }
}
```

The helper used above can be implemented as:

```swift
private static func imagePasteStamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
}
```

## Links, file links, and drops

`bridge.onOpenLink` is called with an already resolved absolute URL when the user
Cmd-clicks a link or an inline-code markdown path. Your host decides whether to
open file URLs in-app, open web URLs through `NSWorkspace`, or apply custom
routing.

Recommended behavior:

- For `file://` markdown files, open them in your own document/tab system.
- For `http` / `https`, use `NSWorkspace.shared.open(url)`.
- For unsupported schemes, either hand off to `NSWorkspace` or reject explicitly.
- If your app has a workspace root, set `bridge.workspaceRootURL`; relative link
  resolution can use it as a secondary base.

Inline-code path navigation is built into the library. When the user Cmd-clicks
an inline `` `code` `` span whose text looks like a markdown file path, the
library treats it like a link and calls `onOpenLink`. This is navigation-only:
the markdown source is not rewritten, and the backticks stay on disk.

Recognized inline-code paths must end with one of these extensions, optionally
followed by a fragment:

```text
.md
.markdown
.mdown
.mkd
.md#heading
```

Examples that are handled by the library:

```markdown
`README.md`
`../notes/idea.md`
`notes/index.markdown`
`notes/index.md#intro`
```

The detection trims surrounding whitespace, ignores empty strings, ignores
strings longer than 512 characters, and ignores inline code containing newlines.
Resolution then follows the normal link path: current document directory first,
then `bridge.workspaceRootURL` for root-relative-looking paths when a workspace
root is configured.

`bridge.onDropURL` is called for file/folder drops onto the editor. The library
does not open dropped files by itself. The host should decide whether the drop
opens a file, opens a folder/workspace, inserts a link, or is ignored.

For “Insert Link to File…” integration, the library handles `Cmd+Shift+K` inside
the editor and calls:

```swift
bridge.onFileLinkPickerRequested: (String?) -> Void
```

The argument is the current selection text, if any. Present your own picker,
compute a relative path from the current document to the selected file, then
insert the link:

```swift
let href = RelativePath.relative(from: sourceFileURL, to: pickedFileURL)
let text = selectedText?.isEmpty == false ? selectedText! : pickedFileURL.deletingPathExtension().lastPathComponent
bridge.insertLink(href: href, text: text)
```

## Find, replace, and outline

Use one `EditorBridge` per editor instance. `FindBar` observes the bridge and
uses its query, replacement, match count, and current-match state:

```swift
VStack(spacing: 0) {
    if bridge.searchVisible {
        FindBar(bridge: bridge)
    }
    MarkdownWebEditor(store: store, bridge: bridge)
}
```

Recommended menu/shortcut wiring:

- `Cmd+F`: `bridge.showFind()`
- `Esc` while find is visible: `bridge.hideFind()`
- `Cmd+G`: `bridge.findNext()`
- `Shift+Cmd+G`: `bridge.findPrev()`

For outline UI, `OutlineView(store:onSelect:)` parses headings from
`store.text`. On selection, call `bridge.scrollToHeading(index:)`.

## Keyboard shortcuts

The library intentionally does not install an app-wide menu or a window-scoped
native key monitor. Host apps should wire native menus and shortcuts themselves.

Library-provided editor-internal shortcuts:

| Shortcut | Behavior |
|---|---|
| `Cmd+K` | Open/edit URL link using Toast UI Editor's link popup. |
| `Cmd+Shift+K` | Request host file-link picker via `onFileLinkPickerRequested`. |
| `Cmd+click` link | Resolve link and call `onOpenLink`, or open non-file URLs with `NSWorkspace` if no callback is set. |
| `Cmd+click` inline code path | Resolve markdown-looking paths and call `onOpenLink`. |
| `*` / `-` / `+` then Space | Auto-convert to bullet list. |
| Enter after a completed task item | Start the next task item unchecked. |

Recommended host shortcuts, matching `markdown-lib` where applicable:

### File / window / tab

| Shortcut | Recommended action |
|---|---|
| `Cmd+N` | New tab/document. |
| `Shift+Cmd+N` | New window. |
| `Cmd+O` | Open file. |
| `Shift+Cmd+O` | Open folder/workspace, if your app has one. |
| `Cmd+P` | Go to file / quick open, if your app has a workspace. |
| `Cmd+S` | Save active document. |
| `Shift+Cmd+S` | Save As. |
| `Cmd+W` | Close active tab/document. |
| `Shift+Cmd+W` | Close window. |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | Next / previous tab. |
| `Cmd+1` ... `Cmd+9` | Jump to tab N. |
| `Shift+Cmd+]` / `Shift+Cmd+[` | Next / previous tab. |

### Edit / find

| Shortcut | Recommended action |
|---|---|
| `Cmd+Z` / `Shift+Cmd+Z` | Standard undo / redo. |
| `Cmd+X/C/V/A` | Standard cut / copy / paste / select all. |
| `Cmd+F` | Show find bar. |
| `Cmd+G` / `Shift+Cmd+G` | Find next / previous. |
| `Esc` | Hide find bar when visible. |
| `Cmd+K` | Leave to the editor, or provide an equivalent link command. |
| `Shift+Cmd+K` | Insert link to file. |

### Format

Format commands should call `bridge.execCommand(...)` on the active editor.
Recommended bindings match `markdown-lib`:

| Shortcut | Command |
|---|---|
| `Cmd+B` | `execCommand("bold")` |
| `Cmd+I` | `execCommand("italic")` |
| `Shift+Cmd+X` | `execCommand("strike")` |
| `Cmd+E` | `execCommand("code")` |
| `Shift+Cmd+E` | `execCommand("codeBlock")` |
| `Option+Cmd+1` ... `Option+Cmd+6` | `execCommand("heading", payload: ["level": n])` |
| `Option+Cmd+P` | `execCommand("heading", payload: ["level": 0])` |
| `Shift+Cmd+U` | `execCommand("bulletList")` |
| `Option+Cmd+L` | `execCommand("orderedList")` |
| `Option+Cmd+K` | `execCommand("taskList")` |
| `Option+Cmd+Q` | `execCommand("blockQuote")` |
| `Option+Cmd+R` | `execCommand("hr")` |
| `Option+Cmd+T` | `execCommand("addTable", payload: ["rowCount": 3, "columnCount": 3])` |

If the WKWebView has first-responder focus, normal `NSMenuItem` key equivalents
may not be enough for every command. `markdown-lib` uses a window-scoped
`NSEvent.addLocalMonitorForEvents(matching: .keyDown)` and filters by window
before dispatching. If you use the same approach, keep the filter window-scoped
so shortcuts in one window do not affect another window.

## Multi-tab recommendations

Use a separate `DocumentStore` and `EditorBridge` for every tab/document.

Do not share one `EditorBridge` across multiple editor instances. Search state,
current match, readiness, and the weak WKWebView reference are editor-specific.

If you want tab switches to preserve cursor, scroll position, and undo history,
keep each tab's `MarkdownWebEditor` alive in the SwiftUI hierarchy and hide
inactive editors with opacity / hit-testing instead of destroying and recreating
the active editor view.

## App-shell responsibilities checklist

A production host app should usually provide:

- Open / Save / Save As UI.
- Close and quit prompts based on `store.isDirty`.
- External modification prompt based on `store.externallyModified`.
- `onOpenLink` routing.
- `onDropURL` behavior.
- `onPasteImage` storage policy.
- Optional file-link picker for `onFileLinkPickerRequested`.
- Native menus and shortcuts, ideally matching the recommendations above.
- One `DocumentStore` + one `EditorBridge` per open editor.
- Tests or manual checks for frontmatter round-tripping, image paste paths, and
  shortcut dispatch in multi-window scenarios.
