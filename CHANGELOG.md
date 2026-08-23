# Changelog

All notable changes to this project are documented here.
Format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.6] - 2026-08-23

### Fixed
- **Continuous "slow scan" log spam.** Even though scans no longer
  blocked the main thread, FSEvents was firing every ~1 s in busy
  monorepos (git background ops, bazel cache churn, IDE indexes),
  triggering a full rescan each time. `FileTreeWatcher` now hands the
  changed paths to `WorkspaceStore.shouldRescan(for:)`, which walks
  each path's ancestor components and skips the rescan when every path
  is confined to an ignored subtree (`node_modules`, `.git`, `bazel-*`,
  anything the built-in list or root `.gitignore` covers, plus
  dot-prefixed dirs like `.idea` / `.venv`).

### Changed
- FSEvents debounce bumped from ~100 ms to 150 ms and now accumulates
  changed paths across all bursts inside the window into one batch.
- The background scan slow-log threshold moved from 50 ms to 500 ms —
  50 ms is way too chatty for tree walks even on quiet repos.

## [0.6.5] - 2026-08-23

### Fixed
- **Multi-second workspace scans blocking the UI.** Opening a large
  monorepo (e.g. Uber's `eats-customer-be`) was walking every
  `node_modules` / `bazel-*` / `build` tree on the main queue —
  `WorkspaceStore.refresh` clocked 1–2 s per FSEvent, producing the
  intermittent stalls users saw.

### Changed
- Scans now run on a background queue (`mdlib.workspace.scan`,
  userInitiated). A version counter drops stale results if a newer scan
  starts before an older one finishes. The `@Published root` assignment
  is the only main-thread work. Workspace windows open instantly with
  an empty tree; the real one fills in a moment later.
- `.gitignore` at the workspace root is now honored. Basename-level
  patterns (with fnmatch(3) globs so `bazel-*`, `*.log`, etc. work)
  are re-read on every scan. Path-scoped patterns (`src/foo`) and
  negations (`!keep`) aren't supported yet.
- Built-in noise-directory list still applies as a safety net:
  `node_modules`, `build`, `dist`, `out`, `target`, `Pods`,
  `DerivedData`, `__pycache__`, `.mypy_cache`, `.pytest_cache`,
  `vendor`, `bazel-*`.
- `scan` caches `resourceValues(isDirectoryKey)` once per URL instead
  of stat-ing each entry three times.

## [0.6.4] - 2026-08-23

### Fixed
- **Idle CPU (~20–50%) with the app doing nothing.** Traced to the
  MutationObserver added in 0.6.2 to re-apply `spellcheck="false"` on
  every DOM attribute change. It caught ProseMirror's continuous
  selection-widget updates and re-ran a `querySelectorAll` each time.
  Removed the observer entirely — `spellcheck` is inherited from the
  HTML body, so a single post-init sweep (0 ms / 250 ms / 1 s) is
  enough. If ProseMirror ever starts explicitly setting `spellcheck="true"`
  on its editable, add a narrower fix.

### Added
- **`PerfLog` + main-thread stall detector** to make future hiccups
  visible. `⚠️ [slow] label: N ms` prints to stderr when a wrapped
  block runs longer than 50 ms; `🚨 [main-stall] N ms — last activity: …`
  prints when the main thread's dispatch latency exceeds 150 ms. The
  detector uses a semaphore-timed probe (no main-thread heartbeat), so
  its baseline cost is near zero. Disable with `MDLIB_PERF=0`.
- Sprinkled `PerfLog.measure` at hot paths: `WorkspaceStore.refresh`,
  `DocumentStore.read` / `write`, and the per-keystroke `store.text = …`
  assignment. Watch Console.app / stderr while reproducing a hiccup to
  see who's on the hook.

## [0.6.3] - 2026-08-23

### Fixed
- **Cmd+click on a relative-path link no longer errors** with "The
  application can't be opened. `-50`" (a Launch Services `paramErr`
  produced by handing it a schemeless URL). The coordinator now
  resolves the `href` against the tab's `fileURL`, opens `file://`
  targets as new tabs via `AppDelegate.open(url:)`, and only routes
  absolute non-file URLs (http, https, mailto, …) to `NSWorkspace`.
- Resolver tries the href both as a URL string (handles `%20` and
  friends) and as a raw filesystem path, so links pasted from other
  tools without percent-encoding also open.
- Fragment-only links (`#heading`) beep instead of trying to open —
  we don't have in-doc anchor navigation yet.
- The WKNavigationDelegate path now goes through the same resolver,
  so any click that slips past the JS interceptor still routes safely
  instead of throwing the raw URL at Launch Services.

## [0.6.2] - 2026-08-23

### Fixed
- **Editing hiccups from macOS spell check.** The WKWebView's built-in
  spell-check path (`applespell`) periodically ran `checkTextInDocument`
  as the user typed, hitching the input queue and producing the
  intermittent "type-type-type … pause" symptom users reported (visible
  as an `applespell` CPU spike in Activity Monitor). We now set
  `spellcheck="false" autocorrect="off" autocapitalize="off" translate="no"`
  on the editor body, and a MutationObserver re-asserts those attributes
  on any contenteditable ProseMirror creates or resets. If you want
  spell check back, remove those attributes in `MarkdownWebEditor.swift`
  (an in-app toggle is a future addition).

## [0.6.1] - 2026-08-23

### Changed
- **Workspace windows stay open after the last tab closes.** The sidebar
  remains visible so the user can pick another file; only loose windows
  (no folder) still close on the last tab (Sublime convention). Title
  bar collapses to just the workspace name when no tab is active. Empty
  editor pane shows a subtle "pick a file / press ⌘N" hint.

### Added
- **File → Open Recent** submenu, populated lazily. Two sections:
  Folders (max 15) then Files (max 20), each shown with the system's
  icon for that URL. Clicking an entry routes through the normal open
  path; entries whose target no longer exists are pruned silently on
  click. **Clear Menu** at the bottom wipes both lists. Persisted in
  `UserDefaults` under `RecentFiles` / `RecentFolders`.

## [0.6.0] - 2026-08-23

### Added
- **Insert Link to File…** (`⌘⇧K`, also in the Edit menu). Opens a
  searchable picker of every markdown file in the current workspace;
  picking a file inserts `[label](relative/path.md)` at the cursor.
- **Relative-path storage.** The path is computed from the current
  file's directory to the target (percent-encoded per component). Works
  for siblings, descendants, ancestors, and cross-tree.
- **Label resolution.** If the user has text selected before the
  shortcut, that becomes the label. Otherwise the target's frontmatter
  `title` (if any) is used, falling back to the basename.
- `RelativePath.relative(from:to:)` helper with 8 assertions covering
  sibling / into-subdir / out-one / out-two / cross-tree / spaces /
  unicode / same-dir.

### Notes
- Untitled tabs get a "save this file first" alert on `⌘⇧K` — the
  relative path needs an anchor.
- Loose (no-workspace) windows fall through (beep) — nothing to pick
  from.

## [0.5.2] - 2026-08-23

### Fixed
- Pressing Enter on an empty line no longer deletes the line. The
  editor's change handler used to re-`setMarkdown` after stripping
  `<br>`-only lines, which nuked the empty paragraph the user had just
  created (Toast UI serializes `<p><br></p>` as a bare `<br>` line).
  The outbound-to-Swift markdown is still normalized, so the on-disk
  file stays clean; the in-editor DOM is left alone. If the original
  "backspace-after-paste eats a list item" bug that motivated the
  round-trip resurfaces, we'll handle it more surgically (paste event
  or a Backspace keydown interceptor).

## [0.5.1] - 2026-08-23

### Added
- **Move** in the sidebar. Right-click any node for **Move to…** (opens
  an `NSOpenPanel` restricted to the workspace root), or **drag** the
  row onto a folder-like target. Drop targets highlight while hovered.
- File-folder sources move their companion directory alongside the `.md`.
- All affected open tabs get their URLs updated automatically (both the
  moved node and anything under a moved directory).

### Notes
- Drop targets are limited to folder-like nodes (real dirs + file-folders).
  Dropping a markdown file onto a plain leaf is a no-op.
- Guards: can't move a directory into itself or a descendant, or into
  its own companion dir. Name conflicts at destination raise an error.

## [0.5.0] - 2026-08-23

### Added
- **File-folder nodes** in the workspace sidebar. When a markdown file
  (`notes.md`) has a same-basename sibling directory (`notes/`), the
  sibling is absorbed as the markdown file's children — the sidebar
  shows one expandable node instead of a file + folder pair. The
  markdown file still opens for editing on click; the disclosure
  indicator expands to reveal the child files.
- **New File / New Folder under any markdown node.** Right-click a
  markdown file in the sidebar and pick New File — if its companion
  directory doesn't exist yet, it's created on demand and the child
  goes inside.
- **Rename couples the pair.** Renaming `notes.md` → `ideas.md` also
  renames `notes/` → `ideas/` (when present), and every open tab
  pointing at either the file or something under the directory gets its
  URL updated automatically.
- **Delete couples the pair.** Deleting a merged markdown node moves
  both the `.md` and the `/` to the Trash; the confirmation names both.
- Multi-extension precedence: when several markdown files share a
  basename with a directory (e.g., `notes.md` and `notes.markdown`
  alongside `notes/`), `.md > .markdown > .mdown > .mkd`. Only the
  winner adopts the directory; the others show as leaves.

### Changed
- `FileNode` gains `companionDirectoryURL`, `isFileFolder`,
  `isFolderLike`, `canAcceptChildren`.
- `WorkspaceStore.rename` returns `[(from, to)]` and `trash` returns
  `[URL]` so the window controller can propagate both the primary
  operation and its companion.
- Folder-like nodes (real dirs + file-folders) sort together, above
  regular files.

## [0.4.2] - 2026-08-23

### Added
- Rename in the workspace sidebar now **auto-follows the `title:`
  frontmatter** when it used to match the old filename. Matches either
  the basename (`title: notes` for `notes.md`) or the full filename
  (`title: notes.md`) and preserves the shape when rewriting. Titles that
  the user set intentionally (different from the filename) are left
  alone.
- `Frontmatter.settingTitle(_:in:)` helper that rewrites the top-level
  `title:` line (or inserts one when missing). Emits a YAML-safe scalar,
  double-quoting when the value contains ambiguous characters
  (`: `, ` #`, leading indicators, quotes, control chars).
- `DocumentStore.setFrontmatter(_:)` + `frontmatterDirty` so programmatic
  frontmatter mutations trip the dirty flag / edited title suffix.

### Notes
- Open-clean tabs are saved immediately after the title update so the
  disk matches what the sidebar shows.
- Open-dirty tabs get the frontmatter mutation in memory only; the
  user's next save carries it to disk along with their edits.

## [0.4.1] - 2026-08-23

### Added
- **YAML frontmatter roundtrip** in `DocumentStore`. Parses `---…---`
  block on read and preserves it verbatim on write, so tools that write
  tags / aliases / custom fields (Obsidian &c.) don't get their metadata
  corrupted.
- **`title:` metadata** picked up as the tab label + window title when
  present, falling back to the filename. No UI to edit yet — this is
  driven by the file's frontmatter.
- `Frontmatter.swift` helper (split / assemble / title extractor).
  Handles CRLF, quoted / unquoted values, inline `# comment` trimming,
  and ignores `title:` under nested maps.

## [0.4.0] - 2026-08-23

### Added
- **FSEvents auto-refresh**: workspace sidebar now updates automatically
  when files change on disk. Recursive watch with a ~300 ms debounce so
  git checkouts / bulk renames coalesce into one refresh.
- **Sidebar context menu**: right-click a file or folder for
  New File · New Folder · Rename… · Delete (to Trash) · Reveal in Finder.
  The sidebar header has a `+` menu for the same actions at the root.
- Rename propagates to any open tab whose file lived at (or under) the
  renamed path via `TabbedDocumentModel.updateAfterRename`.
- Delete cleanly closes clean tabs of removed files; dirty tabs are
  converted to Untitled so the user can Save As before the content is
  gone (`DocumentStore.detachFromDisk`, `retarget(to:)`).

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
