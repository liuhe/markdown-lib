import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controllers: [DocumentWindowController] = []

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if controllers.isEmpty {
            _ = openUntitledWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        _ = openUntitledWindow()
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for path in filenames {
            openFile(at: URL(fileURLWithPath: path))
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // If any dirty windows, prompt for each. Any Cancel aborts quit.
        let dirty = controllers.filter { $0.store.isDirty }
        guard !dirty.isEmpty else { return .terminateNow }
        for c in dirty {
            c.showWindow(nil)
            let choice = c.promptUnsavedChanges(reason: .quitting)
            switch choice {
            case .save:
                if !c.saveSynchronously() { return .terminateCancel }
            case .dontSave:
                continue
            case .cancel:
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    // MARK: - Window/document management

    @discardableResult
    func openUntitledWindow() -> DocumentWindowController {
        let store = DocumentStore()
        return present(store)
    }

    func openFile(at url: URL) {
        // Focus existing window if the file is already open.
        if let existing = controllers.first(where: { $0.store.fileURL == url }) {
            existing.showWindow(nil)
            return
        }
        // Reuse a clean untitled window if available.
        if let reuse = controllers.first(where: { $0.store.fileURL == nil && !$0.store.isDirty }) {
            do {
                try reuse.store.read(from: url)
                reuse.refreshTitleAndDocProxy()
                reuse.showWindow(nil)
            } catch {
                presentError(error)
            }
            return
        }
        let store = DocumentStore()
        do {
            try store.read(from: url)
        } catch {
            presentError(error)
            return
        }
        present(store)
    }

    @discardableResult
    private func present(_ store: DocumentStore) -> DocumentWindowController {
        let c = DocumentWindowController(store: store, delegate: self)
        controllers.append(c)
        c.showWindow(nil)
        return c
    }

    func controllerDidClose(_ controller: DocumentWindowController) {
        controllers.removeAll { $0 === controller }
    }

    // MARK: - Menu actions

    @objc func newDocument(_ sender: Any?) { openUntitledWindow() }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let md = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [md, .plainText]
        }
        if panel.runModal() == .OK {
            for url in panel.urls { openFile(at: url) }
        }
    }

    // MARK: - Menu construction

    private func buildMainMenu() {
        let menubar = NSMenu()

        let appMenuItem = NSMenuItem()
        menubar.addItem(appMenuItem)
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(NSMenuItem(title: "About \(appName)",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide \(appName)",
                                   action: #selector(NSApplication.hide(_:)),
                                   keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All",
                                   action: #selector(NSApplication.unhideAllApplications(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(appName)",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        let fileItem = NSMenuItem()
        menubar.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New", action: #selector(newDocument(_:)), keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(title: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close",
                                    action: #selector(NSWindow.performClose(_:)),
                                    keyEquivalent: "w"))
        fileMenu.addItem(NSMenuItem(title: "Save",
                                    action: #selector(DocumentWindowController.saveDocument(_:)),
                                    keyEquivalent: "s"))
        let saveAs = NSMenuItem(title: "Save As…",
                                action: #selector(DocumentWindowController.saveDocumentAs(_:)),
                                keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        menubar.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo",
                                    action: Selector(("undo:")),
                                    keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo",
                              action: Selector(("redo:")),
                              keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Find…",
                                    action: #selector(DocumentWindowController.performFind(_:)),
                                    keyEquivalent: "f"))
        editMenu.addItem(NSMenuItem(title: "Find Next",
                                    action: #selector(DocumentWindowController.findNext(_:)),
                                    keyEquivalent: "g"))
        let prev = NSMenuItem(title: "Find Previous",
                              action: #selector(DocumentWindowController.findPrevious(_:)),
                              keyEquivalent: "g")
        prev.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(prev)
        editItem.submenu = editMenu

        NSApp.mainMenu = menubar
    }

    // MARK: - Errors

    func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
