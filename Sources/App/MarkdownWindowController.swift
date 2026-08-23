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
            onNewTab: { [weak self] in self?.newTab() }
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
