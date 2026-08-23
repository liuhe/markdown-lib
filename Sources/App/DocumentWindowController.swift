import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// One window ↔ one `DocumentStore`. Owns the SwiftUI hosting view, the
/// per-window key monitor, and the save / reload / close-confirmation flows.
final class DocumentWindowController: NSWindowController, NSWindowDelegate {

    let store: DocumentStore
    let bridge = EditorBridge()
    private weak var appDelegate: AppDelegate?

    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?

    /// Guard so a single external-mod change only prompts once at a time.
    private var externalPromptInFlight = false

    // MARK: - Init

    init(store: DocumentStore, delegate: AppDelegate) {
        self.store = store
        self.appDelegate = delegate

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("MarkdownLibWindow")
        window.registerForDraggedTypes([.fileURL])

        let root = EditorView(store: store, bridge: bridge)
        window.contentView = NSHostingView(rootView: root)

        super.init(window: window)
        window.delegate = self

        refreshTitleAndDocProxy()

        // React to store mutations that affect title / external state.
        store.$text.sink { [weak self] _ in self?.refreshTitle() }
            .store(in: &cancellables)
        store.$fileURL.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshTitleAndDocProxy() }
        }.store(in: &cancellables)
        store.$externallyModified.sink { [weak self] flag in
            guard flag else { return }
            DispatchQueue.main.async { self?.handleExternalModification() }
        }.store(in: &cancellables)

        installKeyMonitor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Title / doc proxy

    func refreshTitleAndDocProxy() {
        refreshTitle()
        window?.representedURL = store.fileURL
    }

    private func refreshTitle() {
        guard let window else { return }
        let base = store.displayName
        window.title = store.isDirty ? "\(base) — Edited" : base
        window.isDocumentEdited = store.isDirty
    }

    // MARK: - Key monitor
    //
    // A local `NSEvent` monitor makes the shortcuts fire even when the WKWebView
    // (a first-responder) would otherwise swallow them.

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.window else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmd = mods.contains(.command)
            let shift = mods.contains(.shift)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            if cmd && !shift {
                switch key {
                case "n": self.appDelegate?.newDocument(nil); return nil
                case "o": self.appDelegate?.openDocument(nil); return nil
                case "s": self.saveDocument(nil); return nil
                case "w": self.window?.performClose(nil); return nil
                case "f": self.performFind(nil); return nil
                case "g": self.findNext(nil); return nil
                default: break
                }
            } else if cmd && shift {
                switch key {
                case "s": self.saveDocumentAs(nil); return nil
                case "g": self.findPrevious(nil); return nil
                default: break
                }
            }
            if event.keyCode == 53 /* Escape */ && self.bridge.searchVisible {
                self.bridge.hideFind()
                return nil
            }
            return event
        }
    }

    // MARK: - Menu actions

    @objc func saveDocument(_ sender: Any?) {
        _ = saveSynchronously()
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        _ = runSaveAsPanel()
    }

    @objc func performFind(_ sender: Any?) { bridge.showFind() }
    @objc func findNext(_ sender: Any?) {
        if !bridge.searchVisible { bridge.showFind() } else { bridge.findNext() }
    }
    @objc func findPrevious(_ sender: Any?) {
        if !bridge.searchVisible { bridge.showFind() } else { bridge.findPrev() }
    }

    // MARK: - Save flow

    /// Returns true on success, false on cancel / error.
    @discardableResult
    func saveSynchronously() -> Bool {
        if let url = store.fileURL {
            do {
                try store.write(to: url)
                refreshTitle()
                return true
            } catch {
                appDelegate?.presentError(error)
                return false
            }
        }
        return runSaveAsPanel()
    }

    private func runSaveAsPanel() -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = store.fileURL?.lastPathComponent ?? "Untitled.md"
        if let md = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [md]
        }
        // Attach as a sheet when we have a window; drain events manually so we
        // can keep the sync save-flow contract (Save/Quit path returns Bool).
        let response: NSApplication.ModalResponse
        if let window {
            response = Self.runAsSheet(panel, on: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return false }
        do {
            try store.write(to: url)
            refreshTitleAndDocProxy()
            return true
        } catch {
            appDelegate?.presentError(error)
            return false
        }
    }

    /// Present `panel` as a sheet on `window` while blocking synchronously by
    /// pumping the run loop until the completion handler fires.
    private static func runAsSheet(_ panel: NSSavePanel,
                                   on window: NSWindow) -> NSApplication.ModalResponse {
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

    // MARK: - Close flow

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard store.isDirty else { return true }
        switch promptUnsavedChanges(reason: .closing) {
        case .save: return saveSynchronously()
        case .dontSave: return true
        case .cancel: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        appDelegate?.controllerDidClose(self)
    }

    // MARK: - Unsaved-changes prompt

    enum PromptReason { case closing, quitting }
    enum PromptChoice { case save, dontSave, cancel }

    func promptUnsavedChanges(reason: PromptReason) -> PromptChoice {
        let alert = NSAlert()
        let name = store.displayName
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
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .dontSave
        default: return .cancel
        }
    }

    // MARK: - External modification prompt

    private func handleExternalModification() {
        guard !externalPromptInFlight else { return }
        externalPromptInFlight = true
        defer { externalPromptInFlight = false }

        let alert = NSAlert()
        let name = store.displayName
        alert.messageText = "“\(name)” has been modified by another application."
        alert.informativeText = store.isDirty
            ? "Reloading will discard the unsaved changes in this window."
            : "Reload the file to see the latest version?"
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Keep Editing")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            store.revertFromDisk()
            refreshTitleAndDocProxy()
        } else {
            store.dismissExternalModification()
        }
    }

    // MARK: - Drag & drop on the window

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(NSDraggingDestination.draggingEntered(_:)) { return true }
        if aSelector == #selector(NSDraggingDestination.performDragOperation(_:)) { return true }
        return super.responds(to: aSelector)
    }
}
