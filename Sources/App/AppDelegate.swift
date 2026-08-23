import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private(set) var controllers: [MarkdownWindowController] = []

    private let recents = RecentsStore.shared
    private var openRecentMenu: NSMenu?

    /// Files handed to `application(_:openFiles:)` before we've finished
    /// launching.
    private var pendingFiles: [URL] = []
    private var didFinishLaunching = false

    /// The empty untitled window we spawn at launch when there's nothing
    /// else to show. Held weakly and cleared as soon as the user either
    /// touches it (adds a tab, opens a file into it, edits) or opens
    /// something into a *different* window (at which point we close it).
    private weak var launchWindow: MarkdownWindowController?

    /// Muted during quit so the flurry of `controllerDidClose` callbacks
    /// (one per window torn down by AppKit on termination) doesn't overwrite
    /// the just-taken pre-quit snapshot with progressively-emptier state.
    private var isTerminating = false

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        MainThreadStallMonitor.shared.start()
        buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        didFinishLaunching = true

        let queued = pendingFiles
        pendingFiles.removeAll()

        if !queued.isEmpty {
            // Explicit files from Finder — honor those, skip session restore.
            for url in queued { open(url: url) }
        } else if !restoreSession() {
            // Nothing to restore: spawn the ephemeral launch window. It'll
            // close itself as soon as the user opens something elsewhere.
            launchWindow = openLooseWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveSession()
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
        // Snapshot *before* any windows close so the saved session reflects
        // what's actually open right now, not the empty state we'd see after
        // AppKit tears each window down during termination.
        saveSession()
        for c in controllers where c.hasDirtyTabs {
            c.showWindow(nil)
            if !c.promptAllDirtyForQuit() { return .terminateCancel }
        }
        isTerminating = true
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
        recents.addFile(url)
        let destination: MarkdownWindowController
        routing: do {
            // 1. If any window already has this file open, focus that tab.
            for c in controllers {
                if let idx = c.tabs.tabs.firstIndex(where: { $0.store.fileURL == url }) {
                    c.tabs.select(idx)
                    destination = c
                    break routing
                }
            }
            // 2. Prefer a window whose workspace contains this file.
            if let containing = controllers.first(where: {
                guard let root = $0.workspace?.rootURL.path else { return false }
                return url.path.hasPrefix(root + "/") || url.path == root
            }) {
                containing.openInNewTab(url)
                destination = containing
                break routing
            }
            // 3. Fall back to the frontmost loose window.
            if let loose = frontmostController(where: { $0.workspace == nil }) {
                loose.openInNewTab(url)
                destination = loose
                break routing
            }
            // 4. Otherwise open a fresh loose window with this file.
            destination = openLooseWindow(initialURL: url)
        }
        destination.showWindow(nil)
        retireLaunchWindowIfPossible(destination: destination)
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
        recents.addFolder(rootURL)
        let c: MarkdownWindowController
        if let existing = controllers.first(where: { $0.workspace?.rootURL == rootURL }) {
            if let initial = initialFile { existing.openInNewTab(initial) }
            c = existing
        } else {
            let workspace = WorkspaceStore(rootURL: rootURL)
            c = MarkdownWindowController(appDelegate: self, workspace: workspace)
            c.bootstrap(with: initialFile)
            controllers.append(c)
        }
        c.showWindow(nil)
        retireLaunchWindowIfPossible(destination: c)
        return c
    }

    /// If the app-launch untitled window is still untouched (one blank clean
    /// tab), close it. If the user's action ended up in the launch window
    /// itself (e.g., `openFile` routed a file into it as a new tab), just
    /// forget it — it's no longer ephemeral.
    private func retireLaunchWindowIfPossible(destination: MarkdownWindowController) {
        guard let launch = launchWindow else { return }
        if launch === destination {
            launchWindow = nil
            return
        }
        let launchTabs = launch.tabs.tabs
        let isUntouched = launchTabs.count == 1
            && launchTabs[0].store.fileURL == nil
            && !launchTabs[0].store.isDirty
        launchWindow = nil
        if isUntouched {
            launch.window?.performClose(nil)
        }
    }

    func controllerDidClose(_ controller: MarkdownWindowController) {
        controllers.removeAll { $0 === controller }
        // Keep session snapshot fresh as windows come and go; that way a
        // crash doesn't lose the state built up between quits. Muted during
        // termination — we already saved the pre-quit snapshot.
        if !isTerminating { saveSession() }
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

        let openRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recentMenu.autoenablesItems = false
        openRecent.submenu = recentMenu
        openRecentMenu = recentMenu
        fileMenu.addItem(openRecent)

        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Go to File…",
                                    action: #selector(MarkdownWindowController.gotoFile(_:)),
                                    keyEquivalent: "p"))
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
        editMenu.addItem(.separator())
        let insertLink = NSMenuItem(title: "Insert Link to File…",
                                    action: #selector(MarkdownWindowController.insertLinkToFile(_:)),
                                    keyEquivalent: "k")
        insertLink.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(insertLink)
        editItem.submenu = editMenu

        NSApp.mainMenu = menubar
    }

    // MARK: - Open Recent

    /// Populate the submenu lazily each time it opens so removals from
    /// missing-file pruning + new opens are reflected without wiring
    /// change-listeners.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openRecentMenu else { return }
        menu.removeAllItems()

        let folders = recents.folders
        let files = recents.files
        var addedAnything = false

        if !folders.isEmpty {
            menu.addItem(sectionHeader("Folders"))
            for url in folders { menu.addItem(recentItem(for: url, isFolder: true)) }
            addedAnything = true
        }
        if !files.isEmpty {
            if addedAnything { menu.addItem(.separator()) }
            menu.addItem(sectionHeader("Files"))
            for url in files { menu.addItem(recentItem(for: url, isFolder: false)) }
            addedAnything = true
        }
        if !addedAnything {
            let empty = NSMenuItem(title: "No Recent Items", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Clear Menu",
                                    action: #selector(clearRecents(_:)),
                                    keyEquivalent: ""))
        }
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func recentItem(for url: URL, isFolder: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: url.lastPathComponent,
                              action: #selector(openRecent(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.toolTip = url.path
        let ws = NSWorkspace.shared
        let icon = ws.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        _ = isFolder    // we currently just show the system icon; kept for future differentiation
        return item
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        // Prune stale entries silently — a moved / deleted item on the recents
        // list shouldn't beep at the user forever.
        guard FileManager.default.fileExists(atPath: url.path) else {
            recents.remove(url)
            NSSound.beep()
            return
        }
        open(url: url)
    }

    @objc private func clearRecents(_ sender: Any?) {
        recents.clearAll()
    }

    // MARK: - Session save / restore

    private let sessionKey = "SessionState_v1"

    private struct SessionSnapshot: Codable {
        struct WindowInfo: Codable {
            let workspacePath: String?
            let tabPaths: [String]
            let activeTabIndex: Int
        }
        let windows: [WindowInfo]
    }

    /// Snapshot every window's workspace + tab file paths + active index.
    /// Untitled / dirty tabs are dropped (nothing to point at on disk);
    /// windows with neither a workspace nor any file tab aren't recorded.
    func saveSession() {
        var snapshotWindows: [SessionSnapshot.WindowInfo] = []
        for c in controllers {
            let tabPaths = c.tabs.tabs.compactMap { $0.store.fileURL?.path }
            let workspacePath = c.workspace?.rootURL.path
            guard workspacePath != nil || !tabPaths.isEmpty else { continue }
            snapshotWindows.append(SessionSnapshot.WindowInfo(
                workspacePath: workspacePath,
                tabPaths: tabPaths,
                activeTabIndex: c.tabs.activeIndex
            ))
        }
        let snap = SessionSnapshot(windows: snapshotWindows)
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: sessionKey)
        }
    }

    /// Try to rebuild the last session. Returns `true` when at least one
    /// window was recreated. Missing folders / files are skipped silently.
    @discardableResult
    private func restoreSession() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let snap = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
        else { return false }

        var restoredAny = false
        for w in snap.windows {
            let validTabURLs = w.tabPaths
                .map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }

            if let wp = w.workspacePath {
                let wsURL = URL(fileURLWithPath: wp)
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: wsURL.path,
                                                            isDirectory: &isDir)
                guard exists, isDir.boolValue else { continue }
                let first = validTabURLs.first
                let c = openWorkspaceWindow(rootURL: wsURL, initialFile: first)
                for u in validTabURLs.dropFirst() { c.openInNewTab(u) }
                let target = min(max(0, w.activeTabIndex), max(0, c.tabs.tabs.count - 1))
                c.tabs.select(target)
                restoredAny = true
            } else if !validTabURLs.isEmpty {
                let c = openLooseWindow(initialURL: validTabURLs[0])
                for u in validTabURLs.dropFirst() { c.openInNewTab(u) }
                let target = min(max(0, w.activeTabIndex), max(0, c.tabs.tabs.count - 1))
                c.tabs.select(target)
                restoredAny = true
            }
        }
        return restoredAny
    }

    // MARK: - Errors

    func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
