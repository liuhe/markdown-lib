# Keyboard Shortcuts

Every shortcut the app accepts, grouped by area. Source of truth:
`Sources/App/AppDelegate.swift` (menu + `NSMenuItem.keyEquivalent`) and
`Sources/App/MarkdownWindowController.swift` (window-scoped
`NSEvent.addLocalMonitorForEvents`).

## Files

| Shortcut | Action |
|---|---|
| `⌘N` | New Tab (in front window) |
| `⇧⌘N` | New Window |
| `⌘O` | Open File… |
| `⇧⌘O` | Open Folder… |
| `⌘P` | Go to File… (fuzzy quick-open) |
| `⌘S` | Save |
| `⇧⌘S` | Save As… |
| `⌘W` | Close Tab (workspace windows keep going; loose windows close on last tab) |
| `⇧⌘W` | Close Window |

## Edit

| Shortcut | Action |
|---|---|
| `⌘Z` / `⇧⌘Z` | Undo / Redo |
| `⌘X` / `⌘C` / `⌘V` | Cut / Copy / Paste |
| `⌘A` | Select All |
| `⌘F` | Find… |
| `⌘G` / `⇧⌘G` | Find Next / Previous |
| `Esc` | Close Find bar |
| `⌘K` | Insert / Edit Link (URL) |
| `⇧⌘K` | Insert Link to File… |

## Format

Headings use the digit-per-level convention; everything else uses letter
mnemonics.

| Shortcut | Action | Mnemonic |
|---|---|---|
| `⌘B` | Bold | |
| `⌘I` | Italic | |
| `⌘⇧X` | Strikethrough | cross out |
| `⌘E` | Code (inline) | |
| `⌘⇧E` | Code Block | shift of Code |
| `⌥⌘1` … `⌥⌘6` | Heading 1 – 6 | digit = level |
| `⌥⌘P` | Paragraph (clear heading) | Paragraph |
| `⌘⇧U` | Bullet List | Unordered / bUllet |
| `⌥⌘L` | Ordered List | numbered List |
| `⌥⌘K` | Task List | checKbox |
| `⌥⌘Q` | Blockquote | Quote |
| `⌥⌘R` | Horizontal Rule | Rule |
| `⌥⌘T` | Table (3×3) | Table |

## View

| Shortcut | Action |
|---|---|
| `⌥⌘0` | Toggle Outline sidebar |

## Tabs

| Shortcut | Action |
|---|---|
| `⌘1` … `⌘9` | Jump to tab N |
| `⌃Tab` / `⌃⇧Tab` | Next / Previous tab |
| `⌘⇧]` / `⌘⇧[` | Next / Previous tab (alternative) |
| `⌘W` | Close active tab |
| Middle-click a tab | Close that tab |
| `⌘T` | New Tab (alias of `⌘N`) |

## Sidebar (workspace mode)

Focus the sidebar (single-click or Tab into it) first — then the arrow
keys drive the tree without leaving your query field or editor.

| Input | Action |
|---|---|
| Click file | Select + open |
| Click directory | Select (does not auto-expand) |
| Click ▸ / ▾ chevron | Toggle expansion (keeps selection) |
| `↑` / `↓` | Move selection |
| `→` | Expand selected dir; if already open, jump to first child |
| `←` | Collapse selected dir; if already closed, jump to parent |
| `Enter` / `Space` | Open file, or toggle dir expansion |
| Right-click empty area | New File / Folder at root, Reveal in Finder |
| Right-click any node | Open / New / Rename / Move… / Delete / Reveal |
| Drag file → folder-like row | Move |

## Mouse & drag-drop

| Input | Action |
|---|---|
| `⌘+click` a link | Open in-app tab (`file://` / relative), or system browser (`http` / `https`) |
| `⌘+click` inline `` `code` `` that ends in `.md` / `.markdown` / `.mdown` / `.mkd` | Open as a tab (resolved against the current file first, then the workspace root) |
| Drag `.md` / folder onto editor window | Open it |
| Drag `.md` / folder onto Dock icon | Open it |
| Middle-click a tab | Close that tab |
