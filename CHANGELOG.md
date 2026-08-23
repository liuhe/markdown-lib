# Changelog

All notable changes to this project are documented here.
Format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-08-23

### Added
- **Workspace mode**: `File → Open Folder…` (`⇧⌘O`) opens a folder as a
  workspace. A sidebar file tree lists every file under the root; clicking
  a text/markdown file opens it as a tab in the same window.
- **Tabs**: every window now has an in-window tab strip. `⌘N` opens a new
  tab in the front window; `⇧⌘N` opens a new window; `⌘W` closes the
  active tab (and the window when the last tab goes); `⌃Tab` / `⌃⇧Tab` and
  `⌘⇧]` / `⌘⇧[` cycle tabs; `⌘1`…`⌘9` jump to a tab. Tabs preserve their
  WKWebView state (cursor, scroll, undo history) across switches.
- **Folder drops**: dropping a directory onto the editor / Dock opens it
  as a workspace window.
- Save As inside a workspace defaults to the workspace root.

### Changed
- Collapsed `DocumentWindowController` into `MarkdownWindowController` —
  now handles both loose-file and workspace windows behind one class.
- `MarkdownWebEditor` now takes a `DocumentStore` (@ObservedObject) rather
  than a raw `Binding<String>` so per-tab state observes correctly.
- Window title shows both the active tab's name and the workspace name
  (e.g. `notes.md — Edited — my-notes/`).

### Removed
- `EditorView.swift` (replaced by `MarkdownWindowView.swift`).
- `DocumentWindowController.swift` (replaced by `MarkdownWindowController.swift`).

## [0.2.1] - 2026-08-23

### Added
- App icon (rounded-square indigo gradient with a white "M↓" mark),
  regenerable from scratch via `scripts/make-icon.swift`.
- `VERSION` file as the single source of truth for the bundle version.
- README, CHANGELOG, and CLAUDE.md at the repo root.
- Buffered file opens: URLs handed to `application(_:openFiles:)` before
  launch completes are now queued and drained after `didFinishLaunching`,
  so Finder double-clicks no longer race the initial empty window.
- `applicationShouldHandleReopen(_:hasVisibleWindows:)`: Dock-click
  deminiaturizes a hidden window instead of doing nothing.
- 0.5 s self-write debounce on the external-modification poll — atomic
  writes and their mtime jitter no longer trip the "modified elsewhere"
  prompt.
- `NSSound.beep()` on find / replace boundaries when there are no matches.

### Changed
- Save As now presents as a window sheet (via a manually pumped run loop)
  so the source document stays visible while picking a location.

## [0.2.0] - 2026-08-23

### Changed
- Rewrote the app around raw `NSApplication` + `NSApplicationDelegate`,
  replacing SwiftUI `App` + `DocumentGroup` entirely. The app now owns its
  window lifecycle, menu bar, and per-window state.
- Replaced `MarkdownDocument: FileDocument` with `DocumentStore`
  (`ObservableObject`) as the per-document state container.

### Added
- `DocumentWindowController` per window, coordinating save / close / reload
  flows, unsaved-change tracking, and dirty-title suffix (` — Edited`).
- `EditorView` SwiftUI shell hosting the Find & Replace bar above the
  WKWebView editor.
- Multi-window with clean-untitled-window reuse when opening files.
- Find & Replace: `⌘F` open, `Esc` / Done close, `⌘G` / `⇧⌘G` navigate,
  live match count. Highlights inject `<span>`s into the ProseMirror DOM;
  replace goes through `view.dispatch(state.tr.insertText(...))` so undo
  history and markdown serialization stay consistent.
- 2 s external-modification polling with a Reload / Keep Editing prompt.
- Drag-and-drop of `.md` / `.markdown` / `.mdown` / `.mkd` onto the editor
  window or the Dock icon.
- Native menu bar (App / File / Edit) with the expected shortcuts.
- Window-scoped local `NSEvent` key monitor so `⌘N/O/S/⇧S/W/F/G/⇧G/Esc`
  fire even when the WKWebView has first-responder focus.
- `representedURL` + `isDocumentEdited` set on each window so the standard
  macOS title-bar proxy icon + close-button dot work.
- `Info.plist` declares `UTImportedTypeDeclarations` covering `.md`,
  `.markdown`, `.mdown`, `.mkd`.
- Build script now runs `swift build -c release`, ad-hoc codesigns, installs
  to `~/Applications/`, and re-registers via `lsregister`.

## [0.1.0] - 2026-08-23

### Added
- Initial import: standalone macOS Markdown editor built on
  SwiftUI `DocumentGroup` + WKWebView hosting Toast UI Editor.
- Inline CSS/JS injection to sidestep `file://` CORS restrictions.
- `<br>`-only-line normalization to keep ProseMirror cursor behavior sane.
- `⌘K` link editor, `⌘+click` to open in the system browser, and the
  `*` / `-` / `+` + space auto bullet-list input rule (dispatched through
  the ProseMirror view rather than `execCommand`).
