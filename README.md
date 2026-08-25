# markdown-lib

A native macOS WYSIWYG Markdown editor. Raw AppKit shell + WKWebView hosting
[Toast UI Editor](https://ui.toast.com/tui-editor) (ProseMirror under the hood).

<p align="center"><img src="AppIcon.icns" width="128" alt="AppIcon"></p>

## Features

- **WYSIWYG editing** — markdown source stays on disk; the editor surface is a
  rich contenteditable via Toast UI Editor.
- **Workspace mode** — `File → Open Folder…` (`⇧⌘O`) opens a folder as a
  workspace with a sidebar file tree; clicking a file opens it as a tab.
- **Tabs + multi-window** — every window has an in-window tab strip. `⌘N`
  new tab · `⇧⌘N` new window · `⌘W` close tab · `⌃Tab` cycle · `⌘1`…`⌘9`
  jump. Tab WKWebView state (cursor, scroll, undo) persists across switches.
- **Find & Replace bar** — `⌘F` to open, `Esc` / Done to close,
  `⌘G` / `⇧⌘G` to navigate, live match count. Beeps on boundaries.
- **Unsaved-change tracking** — dirty flag against the last-saved snapshot;
  `— Edited` title suffix; Save / Don't Save / Cancel dialog on close and quit.
- **External-modification detection** — 2 s polling with a 0.5 s self-write
  debounce; Reload / Keep Editing prompt.
- **Drag-and-drop** — drop `.md` / `.markdown` / `.mdown` / `.mkd` on the
  editor window or the Dock icon.
- **Native menu bar** — App / File / Edit with the shortcuts Cocoa users
  expect. A window-scoped `NSEvent` local monitor makes them fire even when
  the WKWebView holds first-responder focus.
- **⌘K link editor** and **⌘+click** to open in the system browser.
- **Auto bullet list** on `*`/`-`/`+` + space (driven through ProseMirror
  transactions, not `execCommand`).

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.9+ toolchain (installed with Xcode 15+ or the Swift toolchain)

## Build & install

```sh
bash scripts/make-app-bundle.sh
```

The script:
1. Reads `VERSION` (or takes an explicit version as `$1`).
2. Runs `swift build -c release`.
3. Packages into `dist/markdown-lib.app` (bundles the SwiftPM resource bundle
   and `AppIcon.icns` into `Contents/`).
4. Ad-hoc codesigns with `codesign --force --deep --sign -`.
5. Copies to `~/Applications/` and re-registers with Launch Services so file
   associations take effect immediately.

Then launch it from `~/Applications/markdown-lib.app` (or Spotlight).

## Release process

1. Bump `VERSION`.
2. Add an entry to `CHANGELOG.md`.
3. Commit.
4. Tag `vX.Y.Z` and push with `git push --follow-tags`.

The CI pipeline is expected to trigger on the tag and build the release bundle.

## Regenerating the app icon

```sh
swift scripts/make-icon.swift
```

Renders `AppIcon.icns` from scratch — no external assets needed. Tweak
`renderIcon` in the script if you want a different design.

## Layout

```
Sources/App/
  main.swift                     — NSApplication entry
  AppDelegate.swift              — menus, open-file/folder routing, quit prompt
  DocumentStore.swift            — ObservableObject state per document
  WorkspaceStore.swift           — one open folder + recursive file tree
  TabbedDocumentModel.swift      — open-tabs collection + active index
  MarkdownWindowController.swift — one window: sidebar? + tabs + editor
  MarkdownWindowView.swift       — SwiftUI shell (sidebar | tabs / find / editor)
  FileTreeView.swift             — workspace sidebar
  TabBar.swift                   — in-window tab strip
  FindBar.swift                  — find & replace
  EditorBridge.swift             — per-tab imperative search / replace API
  MarkdownWebEditor.swift        — WKWebView + Toast UI Editor bridge (JS/CSS
                                   inlined; search runs inside ProseMirror DOM)
  Resources/toastui/             — bundled Toast UI Editor JS + CSS
scripts/
  make-app-bundle.sh             — build, sign, install
  make-icon.swift                — regenerate AppIcon.icns
VERSION                          — single source of truth for version stamping
AppIcon.icns                     — packed icon set
```

## Using as a library

Just want the editor for your own app? Depend on the `MarkdownEditor`
product:

```swift
.package(url: "https://github.com/liuhe/markdown-lib.git", from: "0.15.0")
// then
.product(name: "MarkdownEditor", package: "markdown-lib")
```

Minimal host code:

```swift
import SwiftUI
import MarkdownEditor

struct MyEditor: View {
    @StateObject private var store = DocumentStore()
    @StateObject private var bridge = EditorBridge()

    var body: some View {
        MarkdownWebEditor(store: store, bridge: bridge)
            .onAppear {
                bridge.onOpenLink   = { url in NSWorkspace.shared.open(url) }
                bridge.onPasteImage = { data, mime in
                    // save `data` somewhere, return the on-disk URL
                }
            }
    }
}
```

The library exports `MarkdownWebEditor`, `EditorBridge`, `DocumentStore`,
`Frontmatter`, `MarkdownOutline` / `OutlineView`, `FindBar`,
`RelativePath`, and `PerfLog` — no window / tab / workspace / recents
code.

For host-app responsibilities, image-paste policy, frontmatter/metadata usage,
shortcut recommendations, and multi-tab gotchas, see
[`INTEGRATING_MARKDOWNEDITOR.md`](INTEGRATING_MARKDOWNEDITOR.md).

## Keyboard shortcuts

See [`SHORTCUTS.md`](SHORTCUTS.md) for the full list — file / edit /
format / view / tab-nav / sidebar / mouse.

## Contributing

See [`CLAUDE.md`](CLAUDE.md) for the internal architecture notes and the
non-obvious gotchas future contributors (human or AI) should know about.
