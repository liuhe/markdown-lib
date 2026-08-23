# CLAUDE.md — internal architecture notes

Working notes for future AI or human contributors. Reading order: this file,
then `README.md` for user-facing details.

## Build & run

```sh
bash scripts/make-app-bundle.sh        # reads VERSION
bash scripts/make-app-bundle.sh 0.3.0  # or pass explicitly
```

Produces `dist/markdown-lib.app`, ad-hoc codesigns it, and installs to
`~/Applications/`. `swift build -c release` alone is enough for a quick
compile check.

Regenerate the icon: `swift scripts/make-icon.swift`.

## Module map

| File | Responsibility |
|---|---|
| `main.swift` | Top-level `NSApp.run()`. No `@main`. |
| `AppDelegate.swift` | Menu bar; open panel + folder panel; URL routing (files → tab, folders → workspace window); deminiaturize on Dock click; quit-with-dirty iterates every dirty tab in every window; buffers pre-launch file opens. |
| `DocumentStore.swift` | `ObservableObject` per document: `text`, `fileURL`, `lastSavedText`, `externallyModified`, disk I/O, 2 s polling timer, 0.5 s self-write debounce. |
| `WorkspaceStore.swift` | Per-window folder root + recursively scanned `FileNode` tree; owns a `FileTreeWatcher` for auto-refresh; exposes `createFile / createFolder / rename / trash` used by the sidebar context menu. |
| `FileTreeWatcher.swift` | `FSEventStream` wrapper. Recursive, debounced (~300 ms), fires `onChange` on main. Started in `WorkspaceStore.init`, stopped in `deinit`. |
| `TabbedDocumentModel.swift` | `[DocumentTab]` + `activeIndex`. `DocumentTab` bundles one `DocumentStore` with its own `EditorBridge` so search state is per-tab. |
| `MarkdownWindowController.swift` | One `NSWindowController` per window. Owns a `TabbedDocumentModel` and an optional `WorkspaceStore`. Wires save / close / reload dialogs (all scoped to the active tab; close-window iterates every dirty tab). Local `NSEvent` monitor handles ⌘N/O/S/⇧S/W/T/F/G/⇧G/⇧O/⇧N, ⌃Tab, ⌘1…⌘9, ⌘⇧[ / ⌘⇧]. |
| `MarkdownWindowView.swift` | SwiftUI shell: `[optional FileTreeView | (TabBar / FindBar / editor ZStack)]`. All tabs stay in the hierarchy behind a ZStack + opacity so their WKWebView keeps cursor/scroll/undo history across switches. |
| `FileTreeView.swift` | Workspace sidebar: `List { OutlineGroup … }`. Single-click opens editable files. |
| `TabBar.swift` | In-window tab strip with dirty dot + hover × + new-tab button. |
| `FindBar.swift` | Find & Replace UI. Owns `@FocusState`; drives the *active tab's* `EditorBridge`. |
| `EditorBridge.swift` | One-per-tab imperative surface + `@Published` state for `FindBar`. |
| `MarkdownWebEditor.swift` | `NSViewRepresentable` around a WKWebView. Loads inlined Toast UI Editor HTML/JS/CSS. Coordinator handles the JS ↔ Swift bridge (`webkit.messageHandlers.editor`). Takes a `DocumentStore` (`@ObservedObject`), not a `Binding<String>`. |

## The web-view bridge

The editor lives in a WKWebView; messages flow both ways through a single
JS message handler named `editor`. Payloads always have a `type` field:

- **JS → Swift**: `ready`, `change`, `openLink`, `searchResult`.
- **Swift → JS**: expose named globals — `window.setMarkdown`, `window.mdSearch`,
  `window.mdFindStep`, `window.mdReplace`, `window.mdReplaceAll`,
  `window.mdClearSearch`.

The Swift `EditorBridge` sends JS by calling `evaluateJavaScript`; string
arguments go through `jsString(_:)` which escapes control chars, U+2028/U+2029,
quotes and backslashes.

Any editing that must round-trip through markdown serialization has to go
through `editor.getCurrentModeEditor().view.dispatch(state.tr…)`. Do **not**
use `document.execCommand` inside Toast UI Editor — it breaks the ProseMirror
state model and undo history. See the auto-bullet-list rule and `mdReplace`
for the pattern.

## Search / replace inside ProseMirror

`highlightMatches` walks text nodes, splits them, and injects
`<span class="md-search-hit">` runs. The currently-selected match gets an
additional `md-search-hit-current` class for a distinct highlight.

Replacement grabs the DOM range of the current span, maps it to a doc
position with `view.posAtDOM`, then dispatches `state.tr.insertText`. This
survives markdown serialization and produces a single undo step per replace.

Editing (any `change` event) tears down search highlights — they'd otherwise
persist as bogus spans in the exported markdown.

## Non-obvious gotchas

1. **SwiftPM resource bundle needs repackaging.** `swift build` emits a
   *flat* bundle at `.build/release/markdown-lib_markdown-lib.bundle/Resources/…`
   with no `Info.plist`. `codesign --deep` refuses to touch it as-is. The
   build script moves `Resources` under `Contents/Resources` and writes a
   minimal `Contents/Info.plist` so `codesign` accepts it while
   `Bundle.module` still resolves the Toast UI assets at runtime.

2. **Save flow is synchronous by contract.** `saveSynchronously()` returns
   `Bool` so the close- and quit-flows can chain Save→Cancel correctly. The
   Save As sheet therefore pumps events manually with
   `NSApp.nextEvent(matching: .any…)` in `runAsSheet(_:on:)`. If you refactor
   to async, adjust `windowShouldClose` and `applicationShouldTerminate`
   accordingly.

3. **Key monitor must filter by window.** `NSEvent.addLocalMonitorForEvents`
   is app-wide. Every controller checks `event.window === self.window` before
   handling; otherwise a keystroke in window A would fire actions in every
   window's controller. Editing this filter is how you get "Cmd+S saves the
   wrong document."

4. **External-modification polling has a self-write debounce.** The store
   records `lastSelfWriteTime` around `write(to:)` and ignores mtime jumps
   within `selfWriteThreshold` (0.5 s). Atomic writes on macOS bump mtime
   twice (temp file + rename), which used to trip the "modified elsewhere"
   dialog on our own saves.

5. **`<br>` normalization.** Toast UI Editor serializes empty paragraphs as
   a bare `<br>` on their own line, but the reverse trip doesn't produce a
   placeable block, so Backspace hops over the empty paragraph and eats the
   previous list item. `normalizeMarkdown` strips those lines. If you ever
   add a `save-as-html` path, remember it will lose these empty lines.

6. **URL entity decoding.** Toast UI Editor emits hrefs with `&amp;` in
   place of `&`. Both the JS side (before posting to Swift) and the Swift
   side (before handing to NSWorkspace) decode these — remove either half
   and Cmd+click will open half-broken URLs.

7. **Pre-launch file opens.** `application(_:openFiles:)` fires *before*
   `applicationDidFinishLaunching` on Finder double-click. `AppDelegate`
   buffers in `pendingFiles` and drains on `didFinishLaunching`; the first
   untitled window is only opened if the queue was empty.

8. **`isReleasedWhenClosed = false`.** Windows are retained by
   `AppDelegate.controllers`. `controllerDidClose(_:)` is the only reference
   drop — do not add manual `close()` paths that bypass it or the array
   leaks.

9. **Tabs stay alive via ZStack + opacity.** `MarkdownWindowView` renders
   every open tab's `MarkdownWebEditor` inside a `ZStack`, toggling
   `.opacity` + `.allowsHitTesting` on the inactive ones. This is what
   keeps each tab's WKWebView cursor / scroll / undo history intact across
   tab switches. Switching to a lazy "only-render-active" model will
   destroy per-tab state — don't.

10. **`EditorBridge` is per-tab, not per-window.** Each `DocumentTab`
    carries its own bridge, so search query / match count / current index
    stay per-tab. The `FindBar` in `MarkdownWindowView` is `.id`-keyed on
    the active tab so it rebuilds when you switch tabs.

11. **`window.tabbingMode = .disallowed`.** We ship our own in-window tab
    strip. macOS native window tabs (`⌘\``, Merge All Windows, etc.)
    would fight the sidebar layout and duplicate our state; keep them off.

12. **⌘W closes tab, not window.** Sublime convention. The controller
    calls `window.performClose(nil)` itself when the last tab is removed;
    `windowShouldClose` then iterates any remaining dirty tabs for
    confirmation before actually closing.

13. **Sidebar file ops trigger *both* an eager refresh and an FSEvents
    refresh.** `WorkspaceStore.createFile` etc. call `refresh()` in the
    same tick so the UI updates immediately; the watcher then fires a
    second `refresh()` a moment later. Both are idempotent — don't add
    debouncing to `refresh()` itself.

14. **Rename must go through `TabbedDocumentModel.updateAfterRename`.**
    Otherwise open tabs for the moved file still hold the old URL,
    external-mod polling stops noticing edits, and saves would recreate
    the old path. The helper handles both leaf renames and directory
    renames (URL prefix rewrite).

15. **Delete: clean tabs close, dirty tabs go Untitled.** Users lose
    data if we just close a dirty tab whose file was trashed. Instead,
    `DocumentStore.detachFromDisk()` clears the URL so the next Save
    triggers Save As.

16. **FSEvents callback is `@convention(c)`.** No captures allowed;
    context is passed via `info` pointer, unwrapped through
    `Unmanaged<FileTreeWatcher>.fromOpaque(info).takeUnretainedValue()`.
    The watcher must outlive the stream (it does — we own the
    `FSEventStreamRef` and stop it in `stop()` / `deinit`).

## Versioning + releases

- `VERSION` is the single source of truth. `make-app-bundle.sh` stamps both
  `CFBundleVersion` and `CFBundleShortVersionString` from it.
- `CHANGELOG.md` is Keep-a-Changelog format; each release gets a `[x.y.z] -
  YYYY-MM-DD` heading.
- Tags are `vX.Y.Z`. CI is expected to build on tag push.

Release ritual: bump `VERSION` → update `CHANGELOG.md` → commit → `git tag
-a vX.Y.Z -m …` → `git push --follow-tags`.

## What NOT to do

- Don't add hidden preference toggles, telemetry, or "first-run" wizards.
  This is a pocket-knife tool.
- Don't reintroduce `DocumentGroup` / `FileDocument`. We migrated off it for
  a reason (multi-window control, precise dirty semantics, deterministic
  save flow).
- Don't `execCommand` inside the WKWebView. Use ProseMirror transactions.
- Don't sign with `--deep` without first fixing the SwiftPM resource
  bundle's `Contents/Info.plist`.
