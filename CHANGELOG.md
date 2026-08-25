# Changelog

All notable changes to this project are documented here.
Format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.14.1] - 2026-08-23

### Fixed
- **Rename `X.md` → `Y.md` now rewrites the file's own
  `(X.assets/…)` and `(X/…)` references** to `(Y.assets/…)` /
  `(Y/…)`. Without this the sibling dir was renamed on disk (already
  worked since 0.5.0 / 0.14.0) but every image / sub-page link inside
  the file itself was left pointing at the gone path, so rename
  silently broke navigation.
- Handles both raw basenames and percent-encoded ones (⇧⌘K's Insert
  Link to File… and our paste-image path emit encoded forms when the
  basename contains spaces / non-ASCII). Three-branch dance mirrors
  `syncTitleFollowingFilename`: open-clean saves immediately;
  open-dirty updates in-memory + lets the user's next save persist;
  not-open reads / rewrites / writes on disk.
- Substring scoping is `(…)` — inside markdown link/image parens — so
  a stray occurrence of the basename word elsewhere in the body isn't
  touched.

## [0.14.0] - 2026-08-23

### Added
- **Paste (or drop) an image → `<basename>.assets/paste-…`.**
  Hooked into Toast UI's `addImageBlobHook`; the JS side sends the blob
  base64-encoded to Swift, which writes it to a sibling `X.assets/`
  directory (created on demand) next to the current file, then hands
  back a relative path so the editor inserts `![](rel/path.png)` for
  you. Filename is `paste-yyyymmdd-HHmmss.<ext>`, with a `-N` counter
  on collision. MIME → extension mapping covers png / jpg / gif / webp
  / svg / heic / tiff / bmp; anything else falls through to png.
  Untitled tabs get a "save this file first" alert (no anchor for
  the `.assets/` dir).
- Sidebar / filesystem plumbing that treats `X.assets/` as part of
  `X.md`:
  - The `.assets/` dir is **hidden from the sidebar** when the paired
    markdown file exists (the paste blobs would just be noise there).
  - **Rename / trash / move** on a markdown file now also handle its
    `.assets/` sibling so the pair never gets split.
  - The FSEvents rescan filter treats any `*.assets` component as
    ignored — paste-image writes don't trigger workspace rescans.

### Known limitation
- Images may render as broken icons inside the WKWebView because our
  editor HTML is loaded with `baseURL: nil` (no local-file access).
  The `.md` on disk is correct — you can preview elsewhere. Follow-up
  work will wire a proper base URL + file-access permission.

## [0.13.1] - 2026-08-23

### Fixed
- **Enter in a completed task item created another completed task
  item.** ProseMirror's default split preserves node attrs on both
  halves, so `checked=true` bled onto the new row. Added a keydown
  Enter observer that, after the default split runs, inspects the
  taskItem now under the caret and — if it's checked — dispatches a
  `setNodeMarkup` transaction to clear the flag. The original stays
  ticked; the new row starts unchecked, ready for the next task.

## [0.13.0] - 2026-08-23

### Added
- **⌘+click on inline `code` that looks like a markdown path opens it.**
  Existing docs often reference sibling files as ``` `../foo.md` ``` or
  ``` `notes/index.md` ```; those are just inline code on disk (and stay
  that way — we don't rewrite anything) but are now clickable at view
  time. JS heuristic: the code text ends in `.md` / `.markdown` /
  `.mdown` / `.mkd` (with optional `#anchor`). Regular inline code
  (variable names, commands) is unaffected.
- Path resolution now tries **two bases in order**: current file's
  directory (classic markdown), then the workspace root (matches the
  "root-relative" convention many project notes use). First candidate
  that exists on disk wins; if none exist, falls back to the classic
  interpretation so the missing-file alert makes sense. Anchor
  `[label](href)` links go through the same code path for consistency.
- `EditorBridge.workspaceRootURL` — populated per tab in
  `MarkdownWindowController.rebindTabSubscriptions`; used only by the
  resolver above.

## [0.12.0] - 2026-08-23

### Added
- **Middle-click a tab to close it.** Scroll-wheel click on the tab
  strip works the way it does in every browser. Left / right clicks
  and drags still reach the underlying SwiftUI tab (implemented via a
  transparent `MiddleClickCatcher` NSView whose `hitTest` only claims
  the hit when `NSApp.currentEvent` is an `otherMouseDown` with button
  number 2).
- **`SHORTCUTS.md`** at the repo root lists every keyboard shortcut
  the app accepts, grouped by area (Files / Edit / Format / View /
  Tabs / Sidebar / Mouse). Linked from the README.

## [0.11.1] - 2026-08-23

### Changed
- **Format shortcuts moved off digits onto letter mnemonics.** The
  `⌘⇧7 / ⌘⇧8 / ⌘⇧9` list combos and the `⌘⇧. / ⌘⇧-` punctuation
  combos are hard to remember; letter keys map to the command name.

  | Command | Old | New |
  |---|---|---|
  | Bullet List | `⌘⇧8` | `⌘⇧U` (Unordered / bUllet) |
  | Ordered List | `⌘⇧7` | `⌥⌘L` (numbered List) |
  | Task List | `⌘⇧9` | `⌥⌘K` (checKbox) |
  | Blockquote | `⌘⇧.` | `⌥⌘Q` (Quote) |
  | Horizontal Rule | `⌘⇧-` | `⌥⌘R` (Rule) |

  Heading 1–6 stays on `⌥⌘1..6` — that mapping is universal (Ulysses,
  Bear, VS Code all do it) and the digits *are* the level.

## [0.11.0] - 2026-08-23

### Added
- **Format menu with keyboard shortcuts** for every toolbar command.
  All items route through `EditorBridge.execCommand` →
  `window.mdExec` → `editor.exec` in Toast UI. Everything works even
  when the WKWebView has focus because AppKit menu shortcuts intercept
  before the browser sees the key.

  | Command | Shortcut |
  |---|---|
  | Bold | `⌘B` |
  | Italic | `⌘I` |
  | Strikethrough | `⌘⇧X` |
  | Code (inline) | `⌘E` |
  | Code Block | `⌘⇧E` |
  | Heading 1–6 | `⌥⌘1` … `⌥⌘6` |
  | Paragraph (clear heading) | `⌥⌘P` |
  | Bullet List | `⌘⇧8` |
  | Ordered List | `⌘⇧7` |
  | Task List | `⌘⇧9` |
  | Blockquote | `⌘⇧.` |
  | Horizontal Rule | `⌘⇧-` |
  | Table (3×3) | `⌥⌘T` |

## [0.10.1] - 2026-08-23

### Fixed
- **Outline showed backslash-escapes in heading text.** Toast UI
  Editor serializes markdown-punctuation inside heading text with
  literal backslashes (`1.` → `1\.`, `(Business)` → `\(Business\)`,
  etc.) so headings displayed as `1\. 业务和功能 \(Business\)` in the
  outline panel. Added CommonMark backslash-unescape: `\` followed by
  ASCII punctuation renders as the punctuation alone; anything else
  (e.g., `\n`, `\：`) is left literal.

## [0.10.0] - 2026-08-23

### Added
- **Right-side outline sidebar** with the active document's ATX
  headings, indented per level. Click a heading to scroll it into view
  in the editor. Empty state shows "No headings" so an untitled tab
  isn't blank noise.
- **View menu → Show Outline (`⌥⌘0`)** toggles it. Also on the
  window-scoped key monitor so it fires with the WKWebView focused.
  State is persisted via `@AppStorage("OutlineVisible")` so both
  windows (and next launch) reflect the same preference.
- `MarkdownOutline` — line-based ATX heading extractor. Skips fenced
  code blocks (```` ``` ```` and ` ~~~ `), skips 4-space-indented lines
  (CommonMark code-block rule), and strips closed `##` trailing
  hashes. Setext (underlined) headings aren't parsed yet.
- `EditorBridge.scrollToHeading(index:)` + JS
  `window.mdScrollToHeading(n)` — matches by heading index in document
  order so duplicate heading text doesn't confuse the jump.

## [0.9.0] - 2026-08-23

### Added
- **Session restore on launch.** When the app quits, every open window
  is snapshotted to `UserDefaults` (workspace root + list of file paths
  per tab + active-tab index). Next launch restores each window that
  still exists; missing paths / folders are silently skipped. Snapshot
  is captured at `applicationShouldTerminate` (before AppKit tears the
  windows down); per-window closes update it too so a crash doesn't
  lose state built up between quits.
- **Retire the launch untitled window automatically.** The empty
  window we spawn at launch (when there's nothing else to show) is
  tracked as `launchWindow`. As soon as the user opens a file or folder
  that lands in a *different* window, if the launch window is still
  untouched (one blank clean tab, nothing typed), it closes itself.
  If the user's action routes into the launch window (e.g., File →
  Open File… into the loose window replaces the untitled tab), we
  just forget the tracker — it's a real editing surface now.

### Notes
- Session restore skips windows whose stored files/folders no longer
  exist on disk, so moving a workspace out from under the app is
  safe — worst case the window is dropped and a fresh untitled shows.
- Untitled / dirty tabs aren't persisted (there's no on-disk anchor
  for them). If you had unsaved work in an untitled tab on quit, macOS
  wouldn't have let you quit without a Save dialog anyway.

## [0.8.1] - 2026-08-23

### Fixed
- **↑/↓ in the ⌘P / ⇧⌘K picker** now move the highlighted result
  instead of the text cursor inside the search field. Focus stays on
  the search field so typing continues to filter; a `ScrollViewReader`
  keeps the highlighted row scrolled into the center of the list.

## [0.8.0] - 2026-08-23

### Added
- **Go to File… (`⌘P`)** — Sublime-style fuzzy picker for opening any
  workspace markdown file. Also in File → Go to File…. Ranking is
  simple fuzzy score with a big boost for basename hits and word-
  boundary matches (`-` / `_` / `/` / `.` / space). Enter opens the
  top match; Esc cancels.
- **Sidebar empty-area right-click menu.** Right-click on the empty
  area below the file tree shows New File / New Folder / Reveal in
  Finder (all rooted at the workspace).
- **Sidebar action bar** grows two buttons next to the `+` menu:
  - **Reveal Active File** (`scope` icon). Walks the FileNode graph,
    expands every ancestor of the current tab's file, sets the sidebar
    selection to it. Handles file-folder nodes (`X.md` adopting `X/`)
    correctly by walking the tree, not the path.
  - **Collapse All** (`rectangle.compress.vertical` icon). Clears the
    expansion set; the tree collapses back to root children.

### Fixed
- **Selected folder icon disappeared** against the accent-color selected
  row background. On the selected row the icon (and disclosure chevron)
  now uses `.primary` so it contrasts against the highlight.

### Changed
- `FileLinkPicker` renamed / generalized to `WorkspaceFilePicker`
  (`title` parameter added; old name kept as a typealias). Both `⌘P`
  and `⇧⌘K` use it.

## [0.7.0] - 2026-08-23

### Changed
- **Sidebar overhaul.** Replaced the SwiftUI `OutlineGroup` renderer
  with a flat `List` we drive ourselves so we can control expansion
  and selection from the keyboard. Directories now use filled folder
  icons in the accent color; markdown files use `doc.text` in
  secondary, non-editable files fade further.

### Added
- **Selection + keyboard navigation in the sidebar.**
  - `↑` / `↓`: move selection up / down across visible rows.
  - `→`: expand the selected directory; if it's already open, jump to
    the first child.
  - `←`: collapse the selected directory; if it's already closed,
    jump to the parent.
  - `Enter` / `Space`: open selected file, or toggle expansion of
    selected directory.
  - Click on a file still opens it (existing behavior); click on a
    directory selects only; click on the ▸ / ▾ chevron toggles
    expansion without moving selection.
- Active-file (currently open in a tab) rows show in bold so the
  selection and the currently-editing document are distinguishable.

## [0.6.9] - 2026-08-23

### Fixed
- **App crashed the first time an FSEvent fired** (SIGSEGV in
  `objc_msgSend` inside the `FileTreeWatcher` callback). Regression
  from 0.6.6: I read the `pathsPtr` argument as an `NSArray` via
  `unsafeBitCast`, but the FSEvents stream was created without
  `kFSEventStreamCreateFlagUseCFTypes`, so `pathsPtr` is a `char**`,
  not an object. Calling `-objectAtIndexedSubscript:` on random C
  bytes → dereference of a garbage isa → crash.
  Fix: add the `UseCFTypes` flag and bridge the `CFArray` properly.



### Changed
- FSEvents debounce bumped 150 ms → 500 ms. With the ignored-subtree
  filter in place, missing a beat by a few hundred ms is invisible;
  the tighter window was more of a burst-multiplier than a
  responsiveness win.
- Background scan slow-log threshold reverted to `PerfLog.slowBlockThreshold`
  (50 ms) — with fewer bogus scans, the finer threshold is useful signal
  again rather than noise.

### Added
- **`[fsevents] rescan: N path(s): a.md, b/c.md, …`** log line whenever
  a change batch survives the ignored-subtree filter. Basename-relative
  paths + count + `(+K more)` suffix. Lets you see what actually
  triggered a rescan (Time Machine snapshot? git background gc?
  Spotlight metadata? one of *your* saves?) without dumping full
  paths.

## [0.6.7] - 2026-08-23

### Changed
- **`PerfLog` lines carry a millisecond-precision timestamp** so you
  can tell "real burst" from "output-buffered flush" apart at a glance
  (`[mdlib 14:22:07.184] ⚠️ [slow] …`).
- `setvbuf(stderr, nil, _IONBF, 0)` at monitor start — belt-and-
  suspenders in case some layer between the process and Terminal
  starts block-buffering stderr (piped through `tee` or a wrapper).

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
