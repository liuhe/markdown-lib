import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var controllers: [MarkdownWindowController] = []

    /// Files handed to `application(_:openFiles:)` before we've finished
    /// launching.
    private var pendingFiles: [URL] = []
    private var didFinishLaunching = false

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        didFinishLaunching = true
        let queued = pendingFiles
        pendingFiles.removeAll()
        for url in queued { open(url: url) }
        if controllers.isEmpty {
            _ = openLooseWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        _ = openLooseWindow()
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if didFinishLaunching {
            for url in urls { open(url: url) }
        } else {
            pendingFiles.append(contentsOf: urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if flag { return true }
        if let miniaturized = controllers.first(where: { $0.window?.isMiniaturized == true }) {
            miniaturized.window?.deminiaturize(nil)
            return false
        }
        if controllers.isEmpty {
            _ = openLooseWindow()
        } else {
            controllers.last?.showWindow(nil)
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for c in controllers where c.hasDirtyTabs {
            c.showWindow(nil)
            if !c.promptAllDirtyForQuit() { return .terminateCancel }
        }
        return .terminateNow
    }

    // MARK: - Window/document management

    /// Route a URL: directories open as workspace windows, files open as tabs
    /// (in the frontmost matching window when possible).
    func open(url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            presentError(NSError(domain: NSCocoaErrorDomain,
                                 code: NSFileReadNoSuchFileError,
                                 userInfo: [NSLocalizedDescriptionKey: "No such file: \(url.path)"]))
            return
        }
        if isDir.boolValue {
            _ = openWorkspaceWindow(rootURL: url)
        } else {
            openFile(at: url)
        }
    }

    func openFile(at url: URL) {
        // 1. If any window already has this file open, focus that tab.
        for c in controllers {
            if let idx = c.tabs.tabs.firstIndex(where: { $0.store.fileURL == url }) {
                c.tabs.select(idx)
                c.showWindow(nil)
                return
            }
        }
        // 2. Prefer a window whose workspace contains this file.
        if let containing = controllers.first(where: {
            guard let root = $0.workspace?.rootURL.path else { return false }
            return url.path.hasPrefix(root + "/") || url.path == root
        }) {
            containing.openInNewTab(url)
            containing.showWindow(nil)
            return
        }
        // 3. Fall back to the frontmost loose window.
        if let loose = frontmostController(where: { $0.workspace == nil }) {
            loose.openInNewTab(url)
            loose.showWindow(nil)
            return
        }
        // 4. Otherwise open a fresh loose window with this file.
        let c = openLooseWindow(initialURL: url)
        c.showWindow(nil)
    }

    @discardableResult
    func openLooseWindow(initialURL: URL? = nil) -> MarkdownWindowController {
        let c = MarkdownWindowController(appDelegate: self, workspace: nil)
        c.bootstrap(with: initialURL)
        controllers.append(c)
        c.showWindow(nil)
        return c
    }

    @discardableResult
    func openWorkspaceWindow(rootURL: URL, initialFile: URL? = nil) -> MarkdownWindowController {
        if let existing = controllers.first(where: { $0.workspace?.rootURL == rootURL }) {
            if let initial = initialFile { existing.openInNewTab(initial) }
            existing.showWindow(nil)
            return existing
        }
        let workspace = WorkspaceStore(rootURL: rootURL)
        let c = MarkdownWindowController(appDelegate: self, workspace: workspace)
        c.bootstrap(with: initialFile)
        controllers.append(c)
        c.showWindow(nil)
        return c
    }

    func controllerDidClose(_ controller: MarkdownWindowController) {
        controllers.removeAll { $0 === controller }
    }

    private func frontmostController(where predicate: (MarkdownWindowController) -> Bool) -> MarkdownWindowController? {
        let ordered = NSApp.orderedWindows
        for w in ordered {
            if let c = controllers.first(where: { $0.window === w }), predicate(c) { return c }
        }
        return controllers.first(where: predicate)
    }

    private func frontmostController() -> MarkdownWindowController? {
        frontmostController(where: { _ in true })
    }

    // MARK: - Menu actions

    @objc func newDocument(_ sender: Any?) {
        // ⌘N: new tab in front window; if there is none, new loose window.
        if let c = frontmostController() {
            c.newTab()
            c.showWindow(nil)
        } else {
            _ = openLooseWindow()
        }
    }

    @objc func newWindow(_ sender: Any?) {
        _ = openLooseWindow()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let md = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [md, .plainText]
        }
        if panel.runModal() == .OK {
            for url in panel.urls { open(url: url) }
        }
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to open as a workspace."
        if panel.runModal() == .OK, let url = panel.url {
            _ = openWorkspaceWindow(rootURL: url)
        }
    }

    // MARK: - Menu construction

    private func buildMainMenu() {
        let menubar = NSMenu()

        // App menu ----------------------------------------------------------
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

        // File menu ---------------------------------------------------------
        let fileItem = NSMenuItem()
        menubar.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New Tab",
                                    action: #selector(newDocument(_:)),
                                    keyEquivalent: "n"))
        let newWin = NSMenuItem(title: "New Window",
                                action: #selector(newWindow(_:)),
                                keyEquivalent: "n")
        newWin.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(newWin)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Open File…",
                                    action: #selector(openDocument(_:)),
                                    keyEquivalent: "o"))
        let openFolderItem = NSMenuItem(title: "Open Folder…",
                                        action: #selector(openFolder(_:)),
                                        keyEquivalent: "o")
        openFolderItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openFolderItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Tab",
                                    action: #selector(NSWindow.performClose(_:)),
                                    keyEquivalent: "w"))
        fileMenu.addItem(NSMenuItem(title: "Save",
                                    action: #selector(MarkdownWindowController.saveDocument(_:)),
                                    keyEquivalent: "s"))
        let saveAs = NSMenuItem(title: "Save As…",
                                action: #selector(MarkdownWindowController.saveDocumentAs(_:)),
                                keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        fileItem.submenu = fileMenu

        // Edit menu ---------------------------------------------------------
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
                                    action: #selector(MarkdownWindowController.performFind(_:)),
                                    keyEquivalent: "f"))
        editMenu.addItem(NSMenuItem(title: "Find Next",
                                    action: #selector(MarkdownWindowController.findNext(_:)),
                                    keyEquivalent: "g"))
        let prev = NSMenuItem(title: "Find Previous",
                              action: #selector(MarkdownWindowController.findPrevious(_:)),
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
