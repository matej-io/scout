import AppKit
import Quartz

final class ScoutWindow: NSWindow {
    var onFirstResponderChange: ((NSResponder?) -> Void)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(responder)
        if ok { onFirstResponderChange?(responder) }
        return ok
    }
}

/// Holds one or two panes side by side.
final class PaneContainerViewController: NSViewController, NSSplitViewDelegate {
    let splitView = NSSplitView()
    private(set) var panes: [PaneViewController] = []

    override func loadView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        view = splitView
    }

    func add(_ pane: PaneViewController) {
        panes.append(pane)
        addChild(pane)
        splitView.addArrangedSubview(pane.view)
        splitView.adjustSubviews()
        if panes.count == 2 {
            splitView.layoutSubtreeIfNeeded()
            splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
        }
    }

    func remove(_ pane: PaneViewController) {
        panes.removeAll { $0 === pane }
        pane.view.removeFromSuperview()
        pane.removeFromParent()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 220)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 220)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        // Keep the panes' proportions while the window resizes.
        let views = splitView.arrangedSubviews
        guard views.count == 2, oldSize.width > 0 else { splitView.adjustSubviews(); return }
        let ratio = views[0].frame.width / max(1, oldSize.width - splitView.dividerThickness)
        let available = splitView.bounds.width - splitView.dividerThickness
        let first = (available * ratio).rounded()
        views[0].frame = NSRect(x: 0, y: 0, width: first, height: splitView.bounds.height)
        views[1].frame = NSRect(x: first + splitView.dividerThickness, y: 0, width: available - first, height: splitView.bounds.height)
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate, PaneDelegate, SidebarDelegate,
                                  NSSearchFieldDelegate, NSMenuDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let splitController = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let container = PaneContainerViewController()
    private(set) var activePane: PaneViewController!
    var panes: [PaneViewController] { container.panes }

    private var navGroup: NSToolbarItemGroup?
    private var viewGroup: NSToolbarItemGroup?
    private var searchItem: NSSearchToolbarItem?
    private var updateItem: NSToolbarItem?
    private var previewURLs: [URL] = []
    private lazy var shareConfiguration = ShareConfiguration { [weak self] in
        self?.activePane.selectedItems.compactMap { $0.ref.localURL } ?? []
    }

    private enum ToolbarID {
        static let nav = NSToolbarItem.Identifier("nav")
        static let view = NSToolbarItem.Identifier("view")
        static let group = NSToolbarItem.Identifier("group")
        static let newFolder = NSToolbarItem.Identifier("newFolder")
        static let action = NSToolbarItem.Identifier("action")
        static let search = NSToolbarItem.Identifier("search")
        static let share = NSToolbarItem.Identifier("share")
        static let delete = NSToolbarItem.Identifier("delete")
        static let info = NSToolbarItem.Identifier("info")
        static let connect = NSToolbarItem.Identifier("connect")
        static let split = NSToolbarItem.Identifier("split")
        static let quickLook = NSToolbarItem.Identifier("quickLook")
        static let terminal = NSToolbarItem.Identifier("terminal")
        static let update = NSToolbarItem.Identifier("update")
    }

    init(location: Location) {
        let window = ScoutWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 300)
        window.tabbingIdentifier = "ScoutBrowser"
        window.tabbingMode = .automatic
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        sidebar.delegate = self
        // SCOUT_PLAIN_SIDEBAR is a debug switch for offscreen snapshots, which can't capture glass.
        let sidebarItem = ProcessInfo.processInfo.environment["SCOUT_PLAIN_SIDEBAR"] != nil
            ? NSSplitViewItem(viewController: sidebar) : NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: container)
        contentItem.minimumThickness = 300
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        window.contentViewController = splitController

        let pane = makePane(location)
        container.add(pane)
        activePane = pane
        pane.isActive = true

        let toolbar = NSToolbar(identifier: "ScoutToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        window.setContentSize(NSSize(width: 1000, height: 600))
        window.onFirstResponderChange = { [weak self] responder in self?.firstResponderChanged(responder) }
        updateWindowChrome()
        NotificationCenter.default.addObserver(self, selector: #selector(updateAvailabilityChanged), name: Updater.availabilityChanged, object: nil)
        updateAvailabilityChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makePane(_ location: Location) -> PaneViewController {
        let pane = PaneViewController(location: location)
        pane.delegate = self
        return pane
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        for pane in panes { pane.start() }
        activePane.focus()
    }

    // MARK: Pane activation

    private func firstResponderChanged(_ responder: NSResponder?) {
        guard let view = responder as? NSView else { return }
        if let pane = panes.first(where: { view.isDescendant(of: $0.view) }), pane !== activePane {
            setActive(pane)
        }
    }

    private func setActive(_ pane: PaneViewController) {
        activePane = pane
        for p in panes { p.isActive = p === pane }
        updateWindowChrome()
        sidebar.syncSelection()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { refreshPreviewItems() }
    }

    func updateWindowChrome() {
        guard let window, let pane = activePane else { return }
        window.title = pane.displayTitle
        if case .folder(.local(let url)) = pane.location, url.isFileURL {
            window.representedURL = url
            window.standardWindowButton(.documentIconButton)?.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            window.representedURL = nil
        }
        navGroup?.subitems[0].isEnabled = pane.canGoBack
        navGroup?.subitems[1].isEnabled = pane.canGoForward
        viewGroup?.selectedIndex = pane.viewMode.rawValue
        if let field = searchItem?.searchField, field.currentEditor() == nil {
            field.stringValue = pane.searchQuery ?? ""
        }
        window.tab.title = pane.displayTitle
        if window.isMainWindow { ViewOptionsController.shared.refresh() }
    }

    // MARK: PaneDelegate

    func paneDidChangeLocation(_ pane: PaneViewController) {
        if pane === activePane {
            updateWindowChrome()
            sidebar.syncSelection()
        }
    }

    func paneDidChangeSelection(_ pane: PaneViewController) {
        if pane === activePane, QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            refreshPreviewItems()
        }
    }

    func paneDidChangeViewMode(_ pane: PaneViewController) {
        if pane === activePane { updateWindowChrome() }
    }

    func otherPane(of pane: PaneViewController) -> PaneViewController? {
        panes.first { $0 !== pane }
    }

    // MARK: SidebarDelegate

    func sidebar(_ sidebar: SidebarViewController, didSelect location: Location) {
        activePane.navigate(to: location)
    }

    func sidebarActiveLocation(_ sidebar: SidebarViewController) -> Location? {
        activePane?.location
    }

    // MARK: Split panes

    var isSplit: Bool { panes.count > 1 }

    @objc func toggleSplit(_ sender: Any?) {
        if isSplit {
            for pane in panes where pane !== activePane { container.remove(pane) }
            activePane.showsIndicator = false
            activePane.focus()
        } else {
            let pane = makePane(activePane.location)
            container.add(pane)
            pane.start()
            for p in panes { p.showsIndicator = true }
            setActive(pane)
            pane.focus()
        }
        updateWindowChrome()
    }

    @objc func switchPane(_ sender: Any?) {
        guard isSplit, let other = otherPane(of: activePane) else { return }
        setActive(other)
        other.focus()
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, ToolbarID.nav, .flexibleSpace, ToolbarID.view, ToolbarID.group, .space, ToolbarID.newFolder, ToolbarID.action, ToolbarID.update, ToolbarID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, ToolbarID.nav, ToolbarID.view, ToolbarID.group, ToolbarID.newFolder, ToolbarID.action, ToolbarID.search,
         ToolbarID.share, ToolbarID.delete, ToolbarID.info, ToolbarID.connect, ToolbarID.split, ToolbarID.quickLook, ToolbarID.terminal,
         ToolbarID.update, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ToolbarID.nav:
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: [Symbols.image("chevron.left")!, Symbols.image("chevron.right")!],
                                           selectionMode: .momentary, labels: ["Back", "Forward"],
                                           target: self, action: #selector(navClicked(_:)))
            group.label = "Back/Forward"
            group.isNavigational = true
            group.autovalidates = false
            for sub in group.subitems { sub.autovalidates = false }
            group.subitems[0].toolTip = "See folders you viewed previously"
            group.subitems[1].toolTip = "See folders you viewed next"
            navGroup = group
            return group

        case ToolbarID.view:
            let group = NSToolbarItemGroup(itemIdentifier: id, images: ViewMode.allCases.map { Symbols.image($0.symbol)! },
                                           selectionMode: .selectOne, labels: ["Icons", "List", "Columns", "Gallery"],
                                           target: self, action: #selector(viewModeClicked(_:)))
            group.label = "View"
            group.toolTip = "Change the item view"
            group.selectedIndex = activePane.viewMode.rawValue
            viewGroup = group
            return group

        case ToolbarID.group:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = Symbols.image("square.grid.3x1.below.line.grid.1x2")
            item.label = "Group"
            item.toolTip = "Change the item grouping"
            let menu = NSMenu()
            menu.delegate = self
            menu.identifier = NSUserInterfaceItemIdentifier("groupMenu")
            item.menu = menu
            item.showsIndicator = true
            return item

        case ToolbarID.newFolder:
            return button(id, symbol: "folder.badge.plus", label: "New Folder", tip: "Create a new folder", action: #selector(PaneViewController.newFolder(_:)))

        case ToolbarID.action:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = Symbols.image("ellipsis")
            item.label = "Action"
            item.toolTip = "Perform tasks with the selected items"
            let menu = NSMenu()
            menu.delegate = self
            menu.identifier = NSUserInterfaceItemIdentifier("actionMenu")
            item.menu = menu
            item.showsIndicator = false
            return item

        case ToolbarID.search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = "Search"
            item.preferredWidthForSearchField = 190
            item.searchField.delegate = self
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsSearchStringImmediately = false
            searchItem = item
            return item

        case ToolbarID.share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.delegate = shareConfiguration
            item.label = "Share"
            return item

        case ToolbarID.delete:
            return button(id, symbol: "trash", label: "Delete", tip: "Move selected items to the \(Prefs.trashTitle)", action: #selector(PaneViewController.moveToTrash(_:)))
        case ToolbarID.info:
            return button(id, symbol: "info.circle", label: "Get Info", tip: "Show information about the selected items", action: #selector(PaneViewController.getInfo(_:)))
        case ToolbarID.connect:
            return button(id, symbol: "server.rack", label: "Connect", tip: "Connect to a server", action: #selector(connectToServer(_:)))
        case ToolbarID.split:
            return button(id, symbol: "rectangle.split.2x1", label: "Split", tip: "Show two listings side by side (⌘S)", action: #selector(toggleSplit(_:)))
        case ToolbarID.quickLook:
            return button(id, symbol: "eye", label: "Quick Look", tip: "Quick Look the selected items", action: #selector(togglePreviewPanel(_:)))
        case ToolbarID.terminal:
            return button(id, symbol: "apple.terminal", label: "Terminal", tip: "Open the folder in Terminal", action: #selector(PaneViewController.openInTerminal(_:)))
        case ToolbarID.update:
            let item = button(id, symbol: "arrow.down.circle", label: "Update", tip: "Update Scout", action: #selector(AppDelegate.checkForUpdates(_:)))
            item.image = item.image?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor]))
            updateItem = item
            refreshUpdateItem()
            return item
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, symbol: String, label: String, tip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = Symbols.image(symbol)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.action = action
        item.isBordered = true
        return item
    }

    /// The Update button stays hidden until Sparkle finds an update. Toolbars saved before it existed don't have it,
    /// so it's added then (toolbars sharing an identifier stay in sync, so adding it to one adds it everywhere).
    @objc private func updateAvailabilityChanged() {
        if Updater.shared.availableVersion != nil, let toolbar = window?.toolbar,
           !toolbar.items.contains(where: { $0.itemIdentifier == ToolbarID.update }) {
            let index = toolbar.items.firstIndex { $0.itemIdentifier == ToolbarID.search } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: ToolbarID.update, at: index)
        }
        refreshUpdateItem()
    }

    private func refreshUpdateItem() {
        let version = Updater.shared.availableVersion
        updateItem?.isHidden = version == nil
        updateItem?.toolTip = version.map { "Scout \($0) is available. Click to update." }
    }

    @objc private func navClicked(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { activePane.goBack() } else { activePane.goForward() }
        activePane.focus()
    }

    @objc private func viewModeClicked(_ sender: NSToolbarItemGroup) {
        guard let mode = ViewMode(rawValue: sender.selectedIndex) else { return }
        activePane.setViewMode(mode)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        activePane.search(sender.stringValue)
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        activePane.search("")
    }

    // MARK: Menus (group popup and action menu)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.identifier?.rawValue == "groupMenu" {
            let header = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let none = NSMenuItem(title: "None", action: #selector(PaneViewController.sortByFromMenu(_:)), keyEquivalent: "")
            none.representedObject = SortKey.none.rawValue
            menu.addItem(none)
            for item in PaneViewController.sortMenu().items {
                menu.addItem(item.copy() as! NSMenuItem)
            }
        } else if menu.identifier?.rawValue == "actionMenu" {
            let source = activePane.contextMenu(for: activePane.selectedItems)
            for item in source.items {
                source.removeItem(item)
                menu.addItem(item)
            }
        }
    }

    // MARK: Actions

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let pane = activePane, pane.responds(to: action) { return pane }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    @objc override func newWindowForTab(_ sender: Any?) {
        guard let window else { return }
        let controller = AppDelegate.shared.makeWindowController(location: activePane.location)
        window.addTabbedWindow(controller.window!, ordered: .above)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func openInNewTab(_ location: Location) {
        guard let window else { return }
        let controller = AppDelegate.shared.makeWindowController(location: location)
        window.addTabbedWindow(controller.window!, ordered: .above)
        controller.showWindow(nil)
    }

    /// Shows a location in the active pane, as `scout <path>` does.
    /// Forced when selecting, so the selection survives a window or tab that’s still loading.
    func show(_ location: Location, select: [ItemRef]) {
        activePane.navigate(to: location, select: select, force: !select.isEmpty)
        activePane.focus()
    }

    func reveal(_ ref: ItemRef) {
        guard let parent = ref.parent else { return }
        activePane.navigate(to: .folder(parent), select: [ref])
    }

    @objc func goToStandardLocation(_ sender: NSMenuItem) {
        let home = Location.home
        let location: Location
        switch sender.tag {
        case 1: location = .recents
        case 2: location = .folder(.local(home.appendingPathComponent("Documents")))
        case 3: location = .folder(.local(home.appendingPathComponent("Desktop")))
        case 4: location = .folder(.local(home.appendingPathComponent("Downloads")))
        case 5: location = .folder(.local(home))
        case 6: location = .computer
        case 7: location = .airdrop
        case 8: location = .network
        case 9: location = .folder(.local(Location.iCloudURL))
        case 10: location = .folder(.local(URL(fileURLWithPath: "/Applications")))
        case 11: location = .folder(.local(URL(fileURLWithPath: "/Applications/Utilities")))
        default: return
        }
        activePane.navigate(to: location)
        activePane.focus()
    }

    @objc func goToFolder(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let pane = activePane!
        GoToFolderController.present(on: window, pane: pane) { location, select in
            pane.navigate(to: location, select: select.map { [$0] } ?? [])
            pane.focus()
        }
    }

    @objc func connectToServer(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Connect to Server"
        alert.informativeText = "Enter an SSH host from ~/.ssh/config, user@host, or ssh://user@host:port/path. smb:// and afp:// addresses open with macOS."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        let recents = Prefs.shared.recentServers
        let hosts = SSHManager.shared.hosts.map(\.destination)
        field.addItems(withObjectValues: recents + hosts.filter { !recents.contains($0) })
        field.placeholderString = "user@example.com"
        field.completes = true
        field.stringValue = recents.first ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.connect(field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    private func connect(_ address: String) {
        guard !address.isEmpty else { return }
        var recents = Prefs.shared.recentServers
        recents.removeAll { $0 == address }
        recents.insert(address, at: 0)
        Prefs.shared.recentServers = recents

        if let url = URL(string: address), let scheme = url.scheme?.lowercased(), ["smb", "afp", "nfs", "vnc", "ftp", "http", "https", "webdav"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        var destination = address
        var path = ""
        if let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "ssh" || scheme == "sftp" {
            var components = URLComponents()
            components.scheme = "ssh"
            components.user = url.user
            components.host = url.host
            components.port = url.port
            destination = url.port != nil ? (components.string ?? address) : ((url.user.map { $0 + "@" } ?? "") + (url.host ?? ""))
            path = url.path
        }
        if !SSHManager.shared.hosts.contains(where: { $0.destination == destination }) {
            SSHManager.shared.addCustomHost(destination)
        }
        let host = SSHManager.shared.host(destination)
        if path.isEmpty {
            activePane.navigate(to: .folder(.remote(host: destination, path: "")))
        } else {
            host.connect { [weak self] result in
                switch result {
                case .success: self?.activePane.navigate(to: .folder(.remote(host: destination, path: path)))
                case .failure(let error): self?.activePane.showError(error)
                }
            }
        }
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        guard let field = searchItem?.searchField else { return }
        window?.makeFirstResponder(field)
    }

    @objc func toggleViewOptions(_ sender: Any?) { ViewOptionsController.shared.toggle() }
    @objc func togglePathBar(_ sender: Any?) { Prefs.shared.showPathBar.toggle() }
    @objc func toggleStatusBar(_ sender: Any?) { Prefs.shared.showStatusBar.toggle() }
    @objc func toggleHiddenFiles(_ sender: Any?) { Prefs.shared.showHidden.toggle() }

    @objc func shareSelection(_ sender: Any?) {
        let urls = activePane.selectedItems.compactMap { $0.ref.localURL }
        guard !urls.isEmpty, let view = activePane.view as NSView? else { return }
        let picker = NSSharingServicePicker(items: urls)
        let rect = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSplit(_:)):
            item.title = isSplit ? "Close Split View" : "Split View"
            item.state = .off
            return true
        case #selector(switchPane(_:)):
            return isSplit
        case #selector(toggleViewOptions(_:)):
            item.title = ViewOptionsController.shared.isVisible ? "Hide View Options" : "Show View Options"
            return true
        case #selector(togglePathBar(_:)):
            item.title = Prefs.shared.showPathBar ? "Hide Path Bar" : "Show Path Bar"
            return true
        case #selector(toggleStatusBar(_:)):
            item.title = Prefs.shared.showStatusBar ? "Hide Status Bar" : "Show Status Bar"
            return true
        case #selector(toggleHiddenFiles(_:)):
            item.title = Prefs.shared.showHidden ? "Hide Hidden Files" : "Show Hidden Files"
            return true
        case #selector(togglePreviewPanel(_:)):
            return !activePane.selectedItems.isEmpty
        case #selector(shareSelection(_:)):
            return activePane.selectedItems.contains { $0.ref.localURL?.isFileURL == true }
        default:
            return true
        }
    }

    // MARK: Quick Look

    @objc func togglePreviewPanel(_ sender: Any?) {
        let panel = QLPreviewPanel.shared()!
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
            return
        }
        refreshPreviewItems {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private var previewToken = 0

    private func refreshPreviewItems(_ completion: (() -> Void)? = nil) {
        previewToken += 1
        let token = previewToken
        let items = activePane.selectedItems
        var urls: [URL?] = Array(repeating: nil, count: items.count)
        let group = DispatchGroup()
        for (index, item) in items.enumerated() {
            switch item.ref {
            case .local(let url):
                urls[index] = url.isFileURL ? url : nil
            case .remote:
                guard !item.isDirectory else { continue }
                group.enter()
                FileOps.cachedCopy(of: item.ref) { result in
                    if case .success(let url) = result { urls[index] = url }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, token == self.previewToken else { return }
            self.previewURLs = urls.compactMap { $0 }
            if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().reloadData() }
            completion?()
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Arrow keys in the panel move the selection in the file view.
        if event.type == .keyDown, let content = activePane.content {
            window?.makeFirstResponder(content.focusView)
            content.focusView.keyDown(with: event)
            return true
        }
        return false
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared.windowClosed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        sidebar.syncSelection()
    }

    /// The title’s path menu (⌘-click or right-click) opens folders in Finder by default;
    /// retarget it to navigate here. Its items run from the folder up to its volume, then the computer.
    func window(_ window: NSWindow, shouldPopUpDocumentPathMenu menu: NSMenu) -> Bool {
        guard let url = window.representedURL else { return true }
        var chain: [URL] = []
        var current = url.standardizedFileURL
        while true {
            chain.append(current)
            let isVolume = (try? current.resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false
            let parent = current.deletingLastPathComponent()
            if isVolume || current.path == "/" || parent.path == current.path { break }
            current = parent
        }
        for (index, item) in menu.items.enumerated() where !item.isSeparatorItem {
            let location: Location = index < chain.count ? .folder(.local(chain[index])) : .computer
            item.representedObject = location
            item.target = self
            item.action = #selector(goToPathMenuLocation(_:))
        }
        return true
    }

    @objc private func goToPathMenuLocation(_ sender: NSMenuItem) {
        guard let location = sender.representedObject as? Location else { return }
        activePane.navigate(to: location)
        activePane.focus()
    }
}

/// Supplies the share toolbar item with the selected files.
final class ShareConfiguration: NSObject, NSSharingServicePickerToolbarItemDelegate {
    private let provider: () -> [URL]
    init(_ provider: @escaping () -> [URL]) { self.provider = provider }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] { provider() }
}

