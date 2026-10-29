import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private var controllers: [MainWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AskPass.install()
        NSApp.mainMenu = MainMenu.build()
        _ = SSHManager.shared
        _ = Updater.shared
        NetworkBrowser.shared.start()
        Snapshot.applyAppearance()
        // Ask for Full Disk Access before the first window touches Desktop, Documents or Downloads.
        if FullDiskAccess.shouldAskAtLaunch {
            FullDiskAccessController.present { [weak self] in self?.openFirstWindow() }
        } else {
            openFirstWindow()
        }
    }

    private func openFirstWindow() {
        newWindow(nil)
        NSApp.activate()
        if ProcessInfo.processInfo.environment["SCOUT_SPRINGTEST"] != nil { SelfTest.runSpring() }
        if let host = ProcessInfo.processInfo.environment["SCOUT_SELFTEST"] {
            SelfTest.run(host: host)
        }
        if let target = ProcessInfo.processInfo.environment["SCOUT_SNAPSHOT"] {
            Snapshot.schedule(to: target)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        SSHManager.shared.disconnectAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Windows

    static var newWindowLocation: Location {
        let finder = UserDefaults(suiteName: "com.apple.finder")
        let home = Location.home
        switch finder?.string(forKey: "NewWindowTarget") {
        case "PfDe": return .folder(.local(home.appendingPathComponent("Desktop")))
        case "PfDo": return .folder(.local(home.appendingPathComponent("Documents")))
        case "PfCm": return .computer
        case "PfVo": return .folder(.local(URL(fileURLWithPath: "/")))
        case "PfAF": return .recents
        case "PfID": return .folder(.local(Location.iCloudURL))
        case "PfLo":
            if let path = finder?.string(forKey: "NewWindowTargetPath"), let url = URL(string: path), url.isFileURL {
                return .folder(.local(url))
            }
            return .folder(.local(home))
        default: return .folder(.local(home))
        }
    }

    func makeWindowController(location: Location) -> MainWindowController {
        let controller = MainWindowController(location: location)
        controllers.append(controller)
        return controller
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = makeWindowController(location: Snapshot.startLocation ?? AppDelegate.newWindowLocation)
        if controllers.count == 1 {
            controller.window?.setFrameAutosaveName("ScoutMainWindow")
            if controller.window?.frame.origin == .zero { controller.window?.center() }
        } else if let key = NSApp.keyWindow {
            controller.window?.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 24, y: key.frame.maxY - 24))
        }
        controller.showWindow(nil)
    }

    func windowClosed(_ controller: MainWindowController) {
        controllers.removeAll { $0 === controller }
    }

    // MARK: App menu actions

    @objc func emptyTrash(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to permanently erase the items in the \(Prefs.trashTitle)?"
        alert.informativeText = "You can’t undo this action."
        alert.addButton(withTitle: "Empty \(Prefs.trashTitle)")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { FileOps.emptyTrash() }
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
    }

    @objc func showFullDiskAccess(_ sender: Any?) {
        if FullDiskAccess.isGranted { FullDiskAccess.openSettings() } else { FullDiskAccessController.present() }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Updater.shared.checkForUpdates()
    }

    @objc func showHelp(_ sender: Any?) {
        if let url = URL(string: "https://github.com/matej-io/scout") { NSWorkspace.shared.open(url) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            menuItem.title = Updater.shared.availableVersion.map { "Update to Scout \($0)…" } ?? "Check for Updates…"
            return Updater.shared.canCheckForUpdates
        }
        return true
    }
}

// MARK: - Main menu (mirrors Finder’s)

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        help.addItem(item("Scout Help", #selector(AppDelegate.showHelp(_:)), "?"))
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.tag = tag
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Scout")
        menu.addItem(item("About Scout", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        menu.addItem(item("Empty \(Prefs.trashTitle)…", #selector(AppDelegate.emptyTrash(_:)), "\u{8}", [.command, .shift]))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide Scout", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Scout", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Scout Window", #selector(AppDelegate.newWindow(_:)), "n"))
        menu.addItem(item("New Folder", #selector(PaneViewController.newFolder(_:)), "n", [.command, .shift]))
        menu.addItem(item("New Tab", #selector(MainWindowController.newWindowForTab(_:)), "t"))
        menu.addItem(item("Open", #selector(PaneViewController.openSelection(_:)), "o"))
        menu.addItem(item("Open in New Tab", #selector(PaneViewController.openInNewTab(_:))))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Get Info", #selector(PaneViewController.getInfo(_:)), "i"))
        menu.addItem(item("Rename", #selector(PaneViewController.renameSelection(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Compress", #selector(PaneViewController.compressItems(_:))))
        menu.addItem(item("Duplicate", #selector(PaneViewController.duplicateItems(_:)), "d"))
        menu.addItem(item("Make Alias", #selector(PaneViewController.makeAlias(_:)), "a", [.command, .control]))
        menu.addItem(item("Quick Look", #selector(MainWindowController.togglePreviewPanel(_:)), "y"))
        menu.addItem(item("Show in Enclosing Folder", #selector(PaneViewController.showInEnclosingFolder(_:)), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Copy to Other Pane", #selector(PaneViewController.copyToOtherPane(_:)), String(Character(UnicodeScalar(NSF5FunctionKey)!)), []))
        menu.addItem(item("Move to Other Pane", #selector(PaneViewController.moveToOtherPane(_:)), String(Character(UnicodeScalar(NSF6FunctionKey)!)), []))
        menu.addItem(.separator())
        menu.addItem(item("Move to \(Prefs.trashTitle)", #selector(PaneViewController.moveToTrash(_:)), "\u{8}"))
        menu.addItem(item("Disconnect", #selector(PaneViewController.ejectHost(_:)), "e"))
        menu.addItem(.separator())
        menu.addItem(item("Open in Terminal", #selector(PaneViewController.openInTerminal(_:)), "t", [.command, .option]))
        menu.addItem(item("Share…", #selector(MainWindowController.shareSelection(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Find", #selector(MainWindowController.performFindPanelAction(_:)), "f"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(PaneViewController.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(PaneViewController.paste(_:)), "v"))
        let move = item("Move Items Here", #selector(PaneViewController.moveItemsHere(_:)), "v", [.command, .option])
        move.isAlternate = true
        menu.addItem(move)
        menu.addItem(item("Copy as Pathname", #selector(PaneViewController.copyPathname(_:)), "c", [.command, .option]))
        menu.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        for mode in ViewMode.allCases {
            menu.addItem(item(mode.title, #selector(PaneViewController.setViewModeFromMenu(_:)), "\(mode.rawValue + 1)", tag: mode.rawValue))
        }
        menu.addItem(.separator())
        let sort = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sortMenu = PaneViewController.sortMenu()
        for (index, item) in sortMenu.items.enumerated() {
            item.keyEquivalent = "\(index + 1)"
            item.keyEquivalentModifierMask = [.command, .option, .control]
        }
        sort.submenu = sortMenu
        menu.addItem(sort)
        menu.addItem(.separator())
        menu.addItem(item("Split View", #selector(MainWindowController.toggleSplit(_:)), "s"))
        menu.addItem(item("Switch to Other Pane", #selector(MainWindowController.switchPane(_:)), "\t", [.option]))
        menu.addItem(.separator())
        menu.addItem(item("Hide Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(item("Show Path Bar", #selector(MainWindowController.togglePathBar(_:)), "p", [.command, .option]))
        menu.addItem(item("Show Status Bar", #selector(MainWindowController.toggleStatusBar(_:)), "/"))
        menu.addItem(item("Show Hidden Files", #selector(MainWindowController.toggleHiddenFiles(_:)), ".", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Show Tab Bar", #selector(NSWindow.toggleTabBar(_:)), "t", [.command, .shift]))
        menu.addItem(item("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Customise Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.addItem(item("Back", #selector(PaneViewController.goBack(_:)), "["))
        menu.addItem(item("Forward", #selector(PaneViewController.goForward(_:)), "]"))
        menu.addItem(item("Enclosing Folder", #selector(PaneViewController.goEnclosingFolder(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))))
        menu.addItem(.separator())
        let go = #selector(MainWindowController.goToStandardLocation(_:))
        menu.addItem(item("Recents", go, "f", [.command, .shift], tag: 1))
        menu.addItem(item("Documents", go, "o", [.command, .shift], tag: 2))
        menu.addItem(item("Desktop", go, "d", [.command, .shift], tag: 3))
        menu.addItem(item("Downloads", go, "l", [.command, .option], tag: 4))
        menu.addItem(item("Home", go, "h", [.command, .shift], tag: 5))
        menu.addItem(item("Computer", go, "c", [.command, .shift], tag: 6))
        menu.addItem(item("AirDrop", go, "r", [.command, .shift], tag: 7))
        menu.addItem(item("Network", go, "k", [.command, .shift], tag: 8))
        menu.addItem(item("iCloud Drive", go, "i", [.command, .shift], tag: 9))
        menu.addItem(item("Applications", go, "a", [.command, .shift], tag: 10))
        menu.addItem(item("Utilities", go, "u", [.command, .shift], tag: 11))
        menu.addItem(.separator())
        menu.addItem(item("Go to Folder…", #selector(MainWindowController.goToFolder(_:)), "l"))
        // Finder’s ⇧⌘G keeps working too.
        let finderShortcut = item("Go to Folder…", #selector(MainWindowController.goToFolder(_:)), "g", [.command, .shift])
        finderShortcut.isHidden = true
        finderShortcut.allowsKeyEquivalentWhenHidden = true
        menu.addItem(finderShortcut)
        menu.addItem(item("Connect to Server…", #selector(MainWindowController.connectToServer(_:)), "k"))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimise", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift]))
        menu.addItem(item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", [.control]))
        menu.addItem(item("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:))))
        menu.addItem(item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
