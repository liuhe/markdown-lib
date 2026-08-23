# markdown-lib

A native macOS WYSIWYG Markdown editor. Raw AppKit shell + WKWebView hosting
[Toast UI Editor](https://ui.toast.com/tui-editor) (ProseMirror under the hood).

<p align="center"><img src="AppIcon.icns" width="128" alt="AppIcon"></p>

## Features

- **WYSIWYG editing** — markdown source stays on disk; the editor surface is a
  rich contenteditable via Toast UI Editor.
- **Multi-window** — one document per window; app stays alive after the last
  window closes; clean untitled windows are reused when opening files.
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
  main.swift                    — NSApplication entry
  AppDelegate.swift             — menus, open flow, deminiaturize, quit prompt
  DocumentStore.swift           — ObservableObject state per document
  DocumentWindowController.swift— per-window controller, save/close/reload
  EditorBridge.swift            — shared handle to the WKWebView + search API
  EditorView.swift              — SwiftUI shell hosting FindBar + web editor
  FindBar.swift                 — Find & Replace bar
  MarkdownWebEditor.swift       — WKWebView + Toast UI Editor bridge (JS/CSS
                                  inlined; search runs inside the ProseMirror
                                  DOM)
  Resources/toastui/            — bundled Toast UI Editor JS + CSS
scripts/
  make-app-bundle.sh            — build, sign, install
  make-icon.swift               — regenerate AppIcon.icns
VERSION                         — single source of truth for version stamping
AppIcon.icns                    — packed icon set
```

See [`CLAUDE.md`](CLAUDE.md) for the internal architecture notes and the
non-obvious gotchas future contributors (human or AI) should know about.
