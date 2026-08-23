import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// One window ↔ (optional workspace folder) + N document tabs.
/// Owns the SwiftUI hosting view, the per-window `NSEvent` monitor, and the
/// save / reload / close-confirmation flows. All flows scope to the active
/// tab except quit-time which iterates every dirty tab.
final class MarkdownWindowController: NSWindowController, NSWindowDelegate {

    let tabs: TabbedDocumentModel
    let workspace: WorkspaceStore?
    private weak var appDelegate: AppDelegate?

    private var cancellables = Set<AnyCancellable>()
    private var tabCancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?

    /// Guard so a single external-mod change per tab only prompts once.
    private var externalPromptInFlight: Set<UUID> = []

    // MARK: - Init

    init(appDelegate: AppDelegate, workspace: WorkspaceStore? = nil) {
        self.tabs = TabbedDocumentModel()
        self.workspace = workspace
        self.appDelegate = appDelegate

        let initialWidth: CGFloat = workspace == nil ? 900 : 1100
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName(workspace == nil ? "MarkdownLibLooseWindow" : "MarkdownLibWorkspaceWindow")
        window.registerForDraggedTypes([.fileURL])
        window.tabbingMode = .disallowed  // we manage our own in-window tab strip

        super.init(window: window)
        window.delegate = self

        let content = MarkdownWindowView(
            tabs: tabs,
            workspace: workspace,
            onOpenFileFromSidebar: { [weak self] url in self?.openInNewTab(url) },
            onCloseTab: { [weak self] idx in self?.closeTab(at: idx) },
            onNewTab: { [weak self] in self?.newTab() },
            onNewFile: { [weak self] parent in self?.promptNewFile(under: parent) },
            onNewFolder: { [weak self] parent in self?.promptNewFolder(under: parent) },
            onRename: { [weak self] url in self?.promptRename(url) },
            onDelete: { [weak self] url in self?.confirmDelete(url) },
            onReveal: { [weak self] url in self?.revealInFinder(url) },
            onMove:   { [weak self] url in self?.promptMove(url) },
            onDropMove: { [weak self] src, dst in _ = self?.performMove(source: src, target: dst) }
        )
        window.contentView = NSHostingView(rootView: content)

        subscribeToActiveTab()
        rebindTabSubscriptions()

        installKeyMonitor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Initial content

    /// Convenience used by the app delegate right after construction.
    func bootstrap(with initialURL: URL?) {
        if let url = initialURL {
            do { try tabs.open(url: url) } catch {
                appDelegate?.presentError(error)
                if tabs.tabs.isEmpty { tabs.addBlank() }
            }
        } else {
            tabs.addBlank()
        }
        refreshTitleAndDocProxy()
    }

    // MARK: - Subscriptions

    private func subscribeToActiveTab() {
        tabs.$activeIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshTitleAndDocProxy() }
            .store(in: &cancellables)
        tabs.$tabs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebindTabSubscriptions()
                self?.refreshTitleAndDocProxy()
            }
            .store(in: &cancellables)
    }

    private func rebindTabSubscriptions() {
        tabCancellables.removeAll()
        for tab in tabs.tabs {
            let id = tab.id
            tab.store.$text
                .receive(on: RunLoop.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab, self.tabs.activeTab?.id == tab.id else { return }
                    self.refreshTitle()
                }
                .store(in: &tabCancellables)
            tab.store.$fileURL
                .receive(on: RunLoop.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab, self.tabs.activeTab?.id == tab.id else { return }
                    self.refreshTitleAndDocProxy()
                }
                .store(in: &tabCancellables)
            tab.store.$rawFrontmatter
                .receive(on: RunLoop.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab, self.tabs.activeTab?.id == tab.id else { return }
                    self.refreshTitle()
                }
                .store(in: &tabCancellables)
            tab.store.$externallyModified
                .receive(on: RunLoop.main)
                .sink { [weak self, weak tab] flag in
                    guard flag, let self, let tab else { return }
                    self.handleExternalModification(for: tab, id: id)
                }
                .store(in: &tabCancellables)
        }
    }

    // MARK: - Title / doc proxy

    func refreshTitleAndDocProxy() {
        refreshTitle()
        window?.representedURL = tabs.activeTab?.store.fileURL
    }

    private func refreshTitle() {
        guard let window else { return }
        let base: String
        if let active = tabs.activeTab {
            let name = active.store.displayName
            base = active.store.isDirty ? "\(name) — Edited" : name
        } else {
            base = "markdown-lib"
        }
        if let ws = workspace {
            window.title = "\(base) — \(ws.rootURL.lastPathComponent)"
        } else {
            window.title = base
        }
        window.isDocumentEdited = tabs.activeTab?.store.isDirty ?? false
    }

    // MARK: - Key monitor

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.window else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmd = mods.contains(.command)
            let shift = mods.contains(.shift)
            let opt = mods.contains(.option)
            let ctrl = mods.contains(.control)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            // Ctrl+Tab / Ctrl+Shift+Tab → cycle tabs (Sublime binding).
            if ctrl && event.keyCode == 48 /* Tab */ && !cmd && !opt {
                if shift { self.tabs.selectPrevious() } else { self.tabs.selectNext() }
                return nil
            }

            if cmd && !shift && !opt {
                switch key {
                case "n": self.newTab(); return nil
                case "o": self.appDelegate?.openDocument(nil); return nil
                case "s": self.saveActiveTab(); return nil
                case "w": self.closeActiveTab(); return nil
                case "t": self.newTab(); return nil
                case "f": self.performFind(nil); return nil
                case "g": self.findNext(nil); return nil
                default:
                    if let n = Int(key), (1...9).contains(n) {
                        self.tabs.selectAbsolute(n); return nil
                    }
                }
            } else if cmd && shift && !opt {
                switch key {
                case "s": self.saveActiveTabAs(); return nil
                case "g": self.findPrevious(nil); return nil
                case "o": self.appDelegate?.openFolder(nil); return nil
                case "n": self.appDelegate?.newWindow(nil); return nil
                case "w": self.closeWindowConfirming(); return nil
                case "]": self.tabs.selectNext(); return nil
                case "[": self.tabs.selectPrevious(); return nil
                default: break
                }
            }

            if event.keyCode == 53 /* Escape */,
               let active = self.tabs.activeTab, active.bridge.searchVisible {
                active.bridge.hideFind()
                return nil
            }
            return event
        }
    }

    // MARK: - Tab actions

    func newTab() {
        tabs.addBlank()
        refreshTitleAndDocProxy()
    }

    func openInNewTab(_ url: URL) {
        do { try tabs.open(url: url) } catch {
            appDelegate?.presentError(error)
        }
        refreshTitleAndDocProxy()
    }

    func closeActiveTab() { closeTab(at: tabs.activeIndex) }

    func closeTab(at index: Int) {
        guard tabs.tabs.indices.contains(index) else { return }
        let tab = tabs.tabs[index]
        if tab.store.isDirty {
            tabs.select(index)
            switch promptUnsavedChanges(for: tab, reason: .closing) {
            case .cancel: return
            case .save:
                if !saveSynchronously(for: tab) { return }
            case .dontSave: break
            }
        }
        let becameEmpty = tabs.remove(at: index)
        if becameEmpty { window?.performClose(nil) }
        else { refreshTitleAndDocProxy() }
    }

    private func closeWindowConfirming() { window?.performClose(nil) }

    // MARK: - Save

    @objc func saveDocument(_ sender: Any?) { saveActiveTab() }
    @objc func saveDocumentAs(_ sender: Any?) { saveActiveTabAs() }

    private func saveActiveTab() { _ = tabs.activeTab.map { saveSynchronously(for: $0) } }
    private func saveActiveTabAs() {
        guard let tab = tabs.activeTab else { return }
        _ = runSaveAsPanel(for: tab)
    }

    @discardableResult
    private func saveSynchronously(for tab: DocumentTab) -> Bool {
        if let url = tab.store.fileURL {
            do {
                try tab.store.write(to: url)
                if tabs.activeTab?.id == tab.id { refreshTitle() }
                return true
            } catch {
                appDelegate?.presentError(error)
                return false
            }
        }
        return runSaveAsPanel(for: tab)
    }

    @discardableResult
    private func runSaveAsPanel(for tab: DocumentTab) -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = tab.store.fileURL?.lastPathComponent ?? "Untitled.md"
        if let md = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [md]
        }
        if let dir = workspace?.rootURL, tab.store.fileURL == nil {
            panel.directoryURL = dir
        }
        let response: NSApplication.ModalResponse
        if let window {
            response = Self.runAsSheet(panel, on: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return false }
        do {
            try tab.store.write(to: url)
            if tabs.activeTab?.id == tab.id { refreshTitleAndDocProxy() }
            workspace?.refresh()
            return true
        } catch {
            appDelegate?.presentError(error)
            return false
        }
    }

    private static func runAsSheet(_ panel: NSSavePanel, on window: NSWindow) -> NSApplication.ModalResponse {
        var response: NSApplication.ModalResponse = .cancel
        var done = false
        panel.beginSheetModal(for: window) { r in
            response = r
            done = true
        }
        while !done {
            if let event = NSApp.nextEvent(matching: .any,
                                           until: .distantFuture,
                                           inMode: .default,
                                           dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        return response
    }

    // MARK: - Find

    @objc func performFind(_ sender: Any?) { tabs.activeTab?.bridge.showFind() }
    @objc func findNext(_ sender: Any?) {
        guard let bridge = tabs.activeTab?.bridge else { return }
        if !bridge.searchVisible { bridge.showFind() } else { bridge.findNext() }
    }
    @objc func findPrevious(_ sender: Any?) {
        guard let bridge = tabs.activeTab?.bridge else { return }
        if !bridge.searchVisible { bridge.showFind() } else { bridge.findPrev() }
    }

    // MARK: - Close-window flow

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Ask about each dirty tab, in order.
        for (i, tab) in tabs.tabs.enumerated() where tab.store.isDirty {
            tabs.select(i)
            switch promptUnsavedChanges(for: tab, reason: .closing) {
            case .cancel: return false
            case .save: if !saveSynchronously(for: tab) { return false }
            case .dontSave: continue
            }
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        appDelegate?.controllerDidClose(self)
    }

    /// Returns `true` when the window can close (used by the terminate flow).
    func requestClose() -> Bool {
        guard let window else { return true }
        return windowShouldClose(window)
    }

    /// Any dirty tab in this window?
    var hasDirtyTabs: Bool { tabs.tabs.contains(where: { $0.store.isDirty }) }

    // MARK: - Unsaved-changes prompt

    enum PromptReason { case closing, quitting }
    enum PromptChoice { case save, dontSave, cancel }

    func promptUnsavedChanges(for tab: DocumentTab, reason: PromptReason) -> PromptChoice {
        let alert = NSAlert()
        let name = tab.store.displayName
        alert.messageText = "Do you want to save the changes made to “\(name)”?"
        alert.informativeText = reason == .quitting
            ? "Your changes will be lost if you don’t save them before quitting."
            : "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "d"
        alert.buttons[1].keyEquivalentModifierMask = [.command]
        alert.buttons[2].keyEquivalent = "\u{1b}"
        showWindow(nil)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .dontSave
        default: return .cancel
        }
    }

    /// Iterate every dirty tab (used by `applicationShouldTerminate`).
    /// Returns `true` when the user resolved (saved or discarded) every dirty
    /// tab, `false` when they cancelled at any point.
    func promptAllDirtyForQuit() -> Bool {
        for (i, tab) in tabs.tabs.enumerated() where tab.store.isDirty {
            tabs.select(i)
            switch promptUnsavedChanges(for: tab, reason: .quitting) {
            case .cancel: return false
            case .save: if !saveSynchronously(for: tab) { return false }
            case .dontSave: continue
            }
        }
        return true
    }

    // MARK: - Sidebar file ops

    func promptNewFile(under parent: URL) {
        guard let workspace else { return }
        guard let name = promptForName(title: "New File",
                                       message: "Enter a filename (e.g. notes.md).",
                                       initial: "untitled.md",
                                       confirm: "Create") else { return }
        do {
            let url = try workspace.createFile(under: parent, name: name)
            openInNewTab(url)
        } catch {
            appDelegate?.presentError(error)
        }
    }

    func promptNewFolder(under parent: URL) {
        guard let workspace else { return }
        guard let name = promptForName(title: "New Folder",
                                       message: "Enter a folder name.",
                                       initial: "New Folder",
                                       confirm: "Create") else { return }
        do { _ = try workspace.createFolder(under: parent, name: name) }
        catch { appDelegate?.presentError(error) }
    }

    func promptRename(_ url: URL) {
        guard let workspace else { return }
        guard let name = promptForName(title: "Rename",
                                       message: "Rename “\(url.lastPathComponent)” to:",
                                       initial: url.lastPathComponent,
                                       confirm: "Rename") else { return }
        if name == url.lastPathComponent { return }
        let oldFilename = url.lastPathComponent
        let oldBasename = url.deletingPathExtension().lastPathComponent
        do {
            let renames = try workspace.rename(url, to: name)
            // Apply the URL rewrites to every affected tab (both the
            // primary rename and the companion-dir rename if there was one).
            for r in renames {
                tabs.updateAfterRename(from: r.from, to: r.to)
            }
            if let primary = renames.first(where: { $0.from == url }) {
                try syncTitleFollowingFilename(from: (oldFilename, oldBasename),
                                               to: primary.to)
            }
            refreshTitleAndDocProxy()
        } catch {
            appDelegate?.presentError(error)
        }
    }

    /// If the frontmatter `title:` used to match the old filename or basename,
    /// rewrite it to match the new one. Users who set an intentional title
    /// (different from the filename) are left alone.
    private func syncTitleFollowingFilename(
        from old: (filename: String, basename: String),
        to newURL: URL
    ) throws {
        guard WorkspaceStore.isEditable(newURL) else { return }
        let newFilename = newURL.lastPathComponent
        let newBasename = newURL.deletingPathExtension().lastPathComponent

        // If the file is currently open in a tab, work on the in-memory copy
        // (avoids racing with the tab's own write path).
        if let tab = tabs.tabs.first(where: { $0.store.fileURL == newURL }) {
            guard let fm = tab.store.rawFrontmatter,
                  let current = Frontmatter.title(in: fm) else { return }
            guard let newTitle = mappedTitle(current: current, old: old,
                                             newFilename: newFilename,
                                             newBasename: newBasename)
            else { return }
            let wasClean = !tab.store.isDirty
            tab.store.setFrontmatter(Frontmatter.settingTitle(newTitle, in: fm))
            // Clean tab: persist immediately so disk matches sidebar.
            // Dirty tab: leave the frontmatter dirty flag; user's next save
            // will carry the title update along with their edits.
            if wasClean { try tab.store.save() }
            return
        }

        // Not open — read, rewrite, write.
        let data = try Data(contentsOf: newURL)
        guard let source = String(data: data, encoding: .utf8) else { return }
        let (fmOpt, body) = Frontmatter.split(source)
        guard let fm = fmOpt, let current = Frontmatter.title(in: fm) else { return }
        guard let newTitle = mappedTitle(current: current, old: old,
                                         newFilename: newFilename,
                                         newBasename: newBasename)
        else { return }
        let updated = Frontmatter.settingTitle(newTitle, in: fm)
        let full = Frontmatter.assemble(frontmatter: updated, body: body)
        try Data(full.utf8).write(to: newURL, options: .atomic)
    }

    private func mappedTitle(current: String,
                             old: (filename: String, basename: String),
                             newFilename: String,
                             newBasename: String) -> String? {
        // Match basename first so `title: notes` (extension-less) survives a
        // rename like `notes.md` → `ideas.md` as `title: ideas`, not
        // `title: ideas.md`.
        if current == old.basename { return newBasename }
        if current == old.filename { return newFilename }
        return nil
    }

    func confirmDelete(_ url: URL) {
        guard let workspace else { return }
        let hasCompanion = workspace.hasCompanionDirectory(url)
        let alert = NSAlert()
        if hasCompanion {
            let dirName = WorkspaceStore.companionDirectoryURL(for: url).lastPathComponent
            alert.messageText = "Move “\(url.lastPathComponent)” and “\(dirName)/” to the Trash?"
            alert.informativeText = "The child folder and everything inside it will be trashed too. You can restore from the Trash later."
        } else {
            alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
            alert.informativeText = "You can restore it from the Trash later."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        showWindow(nil)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        do {
            let trashed = try workspace.trash(url)
            var becameEmpty = false
            for t in trashed {
                if tabs.updateAfterDelete(url: t) { becameEmpty = true }
            }
            if becameEmpty { tabs.addBlank() }
            refreshTitleAndDocProxy()
        } catch {
            appDelegate?.presentError(error)
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Menu-driven move: ask the user for a destination folder via an
    /// `NSOpenPanel` rooted at the workspace, then delegate to `performMove`.
    /// Any user-picked location outside the workspace is rejected with an
    /// error alert.
    func promptMove(_ url: URL) {
        guard let workspace else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.message = "Choose a folder inside the workspace to move “\(url.lastPathComponent)” into."
        panel.directoryURL = url.deletingLastPathComponent()
        // Restrict picking to inside the workspace root.
        let response: NSApplication.ModalResponse
        if let window {
            response = Self.runAsSheet(panel, on: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let dest = panel.url else { return }
        let root = workspace.rootURL.standardizedFileURL.path
        let destPath = dest.standardizedFileURL.path
        guard destPath == root || destPath.hasPrefix(root + "/") else {
            appDelegate?.presentError(WorkspaceStore.FSError.notInWorkspace)
            return
        }
        performMove(source: url, target: dest)
    }

    /// No-prompt move — used by the sidebar drag-and-drop path. `target`
    /// may be a directory or a markdown file (routed through its companion
    /// dir inside `WorkspaceStore.move`).
    @discardableResult
    func performMove(source: URL, target: URL) -> Bool {
        guard let workspace else { return false }
        do {
            let renames = try workspace.move(source, into: target)
            for r in renames {
                tabs.updateAfterRename(from: r.from, to: r.to)
            }
            refreshTitleAndDocProxy()
            return !renames.isEmpty
        } catch {
            appDelegate?.presentError(error)
            return false
        }
    }

    /// Modal single-line prompt using NSAlert + an accessory NSTextField.
    /// Returns the trimmed string on OK, nil on Cancel / empty input.
    private func promptForName(title: String,
                               message: String,
                               initial: String,
                               confirm: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "\u{1b}"

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        // Preselect the basename so typing overwrites it while keeping the
        // extension visible.
        if let dotIdx = initial.lastIndex(of: "."), dotIdx != initial.startIndex {
            let baseCount = initial.distance(from: initial.startIndex, to: dotIdx)
            DispatchQueue.main.async {
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: baseCount)
            }
        } else {
            field.selectText(nil)
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        showWindow(nil)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let s = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // MARK: - External modification prompt

    private func handleExternalModification(for tab: DocumentTab, id: UUID) {
        guard !externalPromptInFlight.contains(id) else { return }
        externalPromptInFlight.insert(id)
        defer { externalPromptInFlight.remove(id) }

        let alert = NSAlert()
        let name = tab.store.displayName
        alert.messageText = "“\(name)” has been modified by another application."
        alert.informativeText = tab.store.isDirty
            ? "Reloading will discard the unsaved changes in this tab."
            : "Reload the file to see the latest version?"
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Keep Editing")
        showWindow(nil)
        // Make sure the offending tab is visible so the user knows what they're
        // reloading.
        if let idx = tabs.tabs.firstIndex(where: { $0.id == id }) { tabs.select(idx) }
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            tab.store.revertFromDisk()
            refreshTitleAndDocProxy()
        } else {
            tab.store.dismissExternalModification()
        }
    }
}
