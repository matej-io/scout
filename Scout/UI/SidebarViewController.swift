import AppKit

final class SidebarItem: NSObject {
    enum Kind { case section, location, host }

    let kind: Kind
    let title: String
    let symbol: String?
    let accent: Bool
    let location: Location?
    let host: SSHHost?
    let tagColor: NSColor?
    var children: [SidebarItem] = []
    let identifier: String

    init(section title: String, children: [SidebarItem]) {
        kind = .section; self.title = title; symbol = nil; accent = false; location = nil; host = nil; tagColor = nil
        identifier = "section:" + title
        self.children = children
    }

    init(title: String, symbol: String?, accent: Bool, location: Location, tagColor: NSColor? = nil) {
        kind = .location; self.title = title; self.symbol = symbol; self.accent = accent; self.location = location
        host = nil; self.tagColor = tagColor
        identifier = "loc:\(location)"
    }

    init(host: SSHHost) {
        kind = .host; title = host.displayName; symbol = "server.rack"; accent = false
        location = .folder(.remote(host: host.destination, path: ""))
        self.host = host; tagColor = nil
        identifier = "host:" + host.destination
    }

    var isEjectable: Bool {
        if let host { return host.isConnected }
        if case .folder(.local(let url)) = location, url.path.hasPrefix("/Volumes/") {
            return (try? url.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey]))
                .map { ($0.volumeIsEjectable ?? false) || ($0.volumeIsRemovable ?? false) } ?? true
        }
        return false
    }
}

protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didSelect location: Location)
    func sidebarActiveLocation(_ sidebar: SidebarViewController) -> Location?
}

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    weak var delegate: SidebarDelegate?
    private let outlineView = SidebarOutlineView()
    private var sections: [SidebarItem] = []
    private var suppressSelection = false
    private lazy var springLoader = SpringLoader(blink: { [weak self] key, on in
        guard let self, let id = key.base as? String else { return }
        for section in self.sections {
            for item in section.children where item.identifier == id {
                let row = self.outlineView.row(forItem: item)
                if row >= 0 { self.outlineView.rowView(atRow: row, makeIfNecessary: false)?.isTargetForDropOperation = on }
            }
        }
    }, open: { [weak self] key in
        guard let self, let id = key.base as? String,
              let item = self.sections.flatMap(\.children).first(where: { $0.identifier == id }),
              let location = item.location else { return }
        (self.view.window?.windowController as? MainWindowController)?.activePane.springOpen(location)
    })
    private static let dragType = NSPasteboard.PasteboardType("io.matej.scout.sidebar-row")

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let column = NSTableColumn(identifier: .init("main"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 0
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.autosaveExpandedItems = false
        outlineView.registerForDraggedTypes([.fileURL, SidebarViewController.dragType])
        outlineView.setDraggingSourceOperationMask([.move, .delete], forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        outlineView.target = self
        outlineView.action = #selector(clicked(_:))
        outlineView.onDragExit = { [weak self] in self?.springLoader.cancel() }

        scroll.documentView = outlineView
        view = scroll

        reload()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload), name: SSHManager.hostsChanged, object: nil)
        nc.addObserver(self, selector: #selector(hostStateChanged(_:)), name: SSHHost.stateChanged, object: nil)
        nc.addObserver(self, selector: #selector(reload), name: Prefs.changed, object: nil)
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(reload), name: NSWorkspace.didMountNotification, object: nil)
        wnc.addObserver(self, selector: #selector(reload), name: NSWorkspace.didUnmountNotification, object: nil)
        wnc.addObserver(self, selector: #selector(reload), name: NSWorkspace.didRenameVolumeNotification, object: nil)
    }

    // MARK: Building

    private func buildSections() -> [SidebarItem] {
        let fm = FileManager.default
        let home = Location.home

        var favorites: [SidebarItem] = []
        if Prefs.shared.showRecents {
            favorites.append(SidebarItem(title: "Recents", symbol: "clock", accent: true, location: .recents))
        }
        for path in Prefs.shared.favorites where fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            favorites.append(SidebarItem(title: fm.displayName(atPath: path), symbol: symbol(forFolder: url), accent: true, location: .folder(.local(url))))
        }

        var locations: [SidebarItem] = []
        if fm.fileExists(atPath: Location.iCloudURL.path) {
            locations.append(SidebarItem(title: "iCloud Drive", symbol: "icloud", accent: false, location: .folder(.local(Location.iCloudURL))))
        }
        locations.append(SidebarItem(title: fm.displayName(atPath: home.path), symbol: "house", accent: false, location: .folder(.local(home))))
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey, .volumeIsInternalKey],
                                           options: [.skipHiddenVolumes]) ?? []
        for url in volumes {
            let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsLocalKey])
            let isInternal = values?.volumeIsInternal ?? (url.path == "/")
            let local = values?.volumeIsLocal ?? true
            let symbol = !local ? "server.rack" : (isInternal ? "internaldrive" : "externaldrive")
            locations.append(SidebarItem(title: values?.volumeLocalizedName ?? url.lastPathComponent, symbol: symbol, accent: false,
                                         location: .folder(.local(url))))
        }
        locations.append(SidebarItem(title: "AirDrop", symbol: "airdrop", accent: false, location: .airdrop))
        locations.append(SidebarItem(title: "Network", symbol: "network", accent: false, location: .network))
        locations.append(SidebarItem(title: Prefs.trashTitle, symbol: "trash", accent: false, location: .folder(.local(Location.trashURL))))

        var result = [SidebarItem(section: Prefs.favoritesTitle, children: favorites),
                      SidebarItem(section: "Locations", children: locations)]

        let hosts = SSHManager.shared.hosts.map(SidebarItem.init(host:))
        result.append(SidebarItem(section: "SSH", children: hosts))

        if Prefs.shared.showTags {
            let tags = FinderTag.all.map {
                SidebarItem(title: $0.name, symbol: nil, accent: false, location: .tag($0.name), tagColor: $0.color)
            }
            result.append(SidebarItem(section: "Tags", children: tags))
        }
        return result
    }

    private func symbol(forFolder url: URL) -> String {
        let home = Location.home
        switch url.path {
        case "/Applications", home.appendingPathComponent("Applications").path: return "appstore"
        case home.appendingPathComponent("Downloads").path: return "arrow.down.circle"
        case home.appendingPathComponent("Desktop").path: return "menubar.dock.rectangle"
        case home.appendingPathComponent("Documents").path: return "doc"
        case home.appendingPathComponent("Movies").path: return "film"
        case home.appendingPathComponent("Music").path: return "music.note"
        case home.appendingPathComponent("Pictures").path: return "photo"
        case home.path: return "house"
        default: return "folder"
        }
    }

    @objc func reload() {
        let expanded = Set(sections.filter { outlineView.isItemExpanded($0) }.map(\.identifier))
        let known = Set(sections.map(\.identifier))
        sections = buildSections()
        suppressSelection = true
        outlineView.reloadData()
        for section in sections where expanded.contains(section.identifier) || !known.contains(section.identifier) {
            outlineView.expandItem(section)
        }
        suppressSelection = false
        syncSelection()
        if ProcessInfo.processInfo.environment["SCOUT_DEBUG"] != nil { NSLog("sidebar rows: %d", outlineView.numberOfRows) }
    }

    @objc private func hostStateChanged(_ note: Notification) {
        guard let host = note.object as? SSHHost else { return }
        for section in sections {
            for item in section.children where item.host === host {
                let row = outlineView.row(forItem: item)
                if row >= 0 { outlineView.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
            }
        }
    }

    /// Highlights the sidebar row matching the active pane's location.
    func syncSelection() {
        guard let location = delegate?.sidebarActiveLocation(self) else { return }
        var match: SidebarItem?
        for section in sections {
            for item in section.children {
                if item.location == location { match = item }
                if match == nil, item.host != nil, case .folder(.remote(let h, let path)) = location,
                   h == item.host?.destination, path == item.host?.home { match = item }
            }
        }
        suppressSelection = true
        if let match {
            let row = outlineView.row(forItem: match)
            if row >= 0 { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
        } else {
            outlineView.deselectAll(nil)
        }
        suppressSelection = false
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? SidebarItem else { return sections.count }
        return item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? SidebarItem else { return sections[index] }
        return item.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.kind == .section
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarItem)?.kind == .section
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarItem)?.kind != .section
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        if item.kind == .section {
            let id = NSUserInterfaceItemIdentifier("HeaderCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = id
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = item.title
            return cell
        }

        let id = NSUserInterfaceItemIdentifier("ItemCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? SidebarCell ?? SidebarCell(identifier: id)
        cell.configure(item, target: self)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem, let location = item.location else { return }
        delegate?.sidebar(self, didSelect: location)
    }

    @objc private func clicked(_ sender: Any?) {
        // Clicking the already-selected row navigates there again (e.g. back to the host's home).
        let row = outlineView.clickedRow
        guard row >= 0, row == outlineView.selectedRow, let item = outlineView.item(atRow: row) as? SidebarItem,
              let location = item.location else { return }
        if delegate?.sidebarActiveLocation(self) != location {
            delegate?.sidebar(self, didSelect: location)
        }
    }

    @objc func eject(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        eject(item)
    }

    private func eject(_ item: SidebarItem) {
        if let host = item.host {
            host.disconnect()
            NotificationCenter.default.post(name: SSHHostDisconnected, object: host.destination)
        } else if case .folder(.local(let url)) = item.location {
            DispatchQueue.global().async {
                try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
            }
        }
    }

    // MARK: Drag and drop (add folders to Favourites, reorder)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? SidebarItem, item.kind == .location,
              case .folder(.local(let url)) = item.location,
              sections.first?.children.contains(item) == true else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(url.path, forType: SidebarViewController.dragType)
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let favorites = sections.first
        // Dropping onto a folder row copies/moves files into it; hovering springs it open in the window.
        if let target = item as? SidebarItem, target.kind != .section, index == NSOutlineViewDropOnItemIndex {
            let isSidebarReorder = info.draggingPasteboard.types?.contains(SidebarViewController.dragType) == true
            springLoader.hover(isSidebarReorder || target.location == nil ? nil : target.identifier)
            guard !isSidebarReorder, let ref = target.location?.ref, !ref.path.isEmpty else { return [] }
            return DragSupport.operation(for: info, destination: ref)
        }
        springLoader.hover(nil)
        // Dropping between favourites adds a folder there.
        if let target = item as? SidebarItem, target === favorites, index != NSOutlineViewDropOnItemIndex {
            if info.draggingPasteboard.types?.contains(SidebarViewController.dragType) == true { return .move }
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            return urls.contains(where: { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) ? .link : []
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        springLoader.cancel()
        DragSupport.noteDrop()
        if let target = item as? SidebarItem, target.kind != .section, index == NSOutlineViewDropOnItemIndex,
           let ref = target.location?.ref {
            return DragSupport.accept(info, destination: ref, window: view.window)
        }
        guard let section = item as? SidebarItem, section === sections.first else { return false }
        var favorites = Prefs.shared.favorites
        let offset = Prefs.shared.showRecents ? 1 : 0
        var insertAt = max(0, min(favorites.count, index - offset))
        if let moved = info.draggingPasteboard.string(forType: SidebarViewController.dragType) {
            if let old = favorites.firstIndex(of: moved) {
                favorites.remove(at: old)
                if old < insertAt { insertAt -= 1 }
            }
            favorites.insert(moved, at: insertAt)
        } else {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            for url in urls.reversed() where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                favorites.removeAll { $0 == url.path }
                favorites.insert(url.path, at: min(insertAt, favorites.count))
            }
        }
        Prefs.shared.favorites = favorites
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Dragging a favourite out of the sidebar removes it, like Finder.
        guard operation == [] || operation == .delete,
              let path = session.draggingPasteboard.string(forType: SidebarViewController.dragType),
              let window = view.window, !window.frame.contains(screenPoint) else { return }
        Prefs.shared.favorites.removeAll { $0 == path }
        NSAnimationEffect.disappearingItemDefault.show(centeredAt: screenPoint, size: NSSize(width: 32, height: 32))
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        if item.kind == .section {
            if item === sections.first {
                let recents = NSMenuItem(title: "Show Recents", action: #selector(toggleRecents(_:)), keyEquivalent: "")
                recents.state = Prefs.shared.showRecents ? .on : .off
                recents.target = self
                menu.addItem(recents)
            }
            if item.title == "SSH" {
                menu.addItem(withTitle: "Connect to Server…", action: #selector(MainWindowController.connectToServer(_:)), keyEquivalent: "")
                menu.addItem(withTitle: "Reload SSH Config", action: #selector(reloadHosts(_:)), keyEquivalent: "").target = self
                if !Prefs.shared.hiddenHosts.isEmpty {
                    menu.addItem(withTitle: "Show Hidden Hosts", action: #selector(showHiddenHosts(_:)), keyEquivalent: "").target = self
                }
            }
            return
        }
        menu.addItem(withTitle: "Open in New Tab", action: #selector(openInNewTab(_:)), keyEquivalent: "").representedObject = item
        if let host = item.host {
            menu.addItem(.separator())
            if host.isConnected {
                menu.addItem(withTitle: "Disconnect", action: #selector(ejectItem(_:)), keyEquivalent: "").representedObject = item
            } else {
                menu.addItem(withTitle: "Connect", action: #selector(connectItem(_:)), keyEquivalent: "").representedObject = item
            }
            menu.addItem(withTitle: "Open in Terminal", action: #selector(openTerminal(_:)), keyEquivalent: "").representedObject = item
            menu.addItem(.separator())
            menu.addItem(withTitle: "Remove from Sidebar", action: #selector(removeItem(_:)), keyEquivalent: "").representedObject = item
        } else {
            if case .folder(.local(let url)) = item.location, url.isFileURL {
                menu.addItem(withTitle: "Show in Enclosing Folder", action: #selector(showEnclosing(_:)), keyEquivalent: "").representedObject = item
            }
            if item.isEjectable {
                menu.addItem(withTitle: "Eject “\(item.title)”", action: #selector(ejectItem(_:)), keyEquivalent: "").representedObject = item
            }
            if sections.first?.children.contains(item) == true {
                menu.addItem(.separator())
                menu.addItem(withTitle: "Remove from Sidebar", action: #selector(removeItem(_:)), keyEquivalent: "").representedObject = item
            }
        }
        for menuItem in menu.items where menuItem.action != #selector(MainWindowController.connectToServer(_:)) && menuItem.target == nil {
            menuItem.target = self
        }
    }

    @objc private func toggleRecents(_ sender: Any?) { Prefs.shared.showRecents.toggle() }
    @objc private func reloadHosts(_ sender: Any?) { SSHManager.shared.reload() }
    @objc private func showHiddenHosts(_ sender: Any?) { Prefs.shared.hiddenHosts = []; SSHManager.shared.reload() }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem, let location = item.location else { return }
        (view.window?.windowController as? MainWindowController)?.openInNewTab(location)
    }

    @objc private func ejectItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem else { return }
        eject(item)
    }

    @objc private func connectItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem, let location = item.location else { return }
        delegate?.sidebar(self, didSelect: location)
    }

    @objc private func openTerminal(_ sender: NSMenuItem) {
        guard let host = (sender.representedObject as? SidebarItem)?.host else { return }
        Terminal.open(.remote(host: host.destination, path: host.isConnected ? host.home : ""))
    }

    @objc private func showEnclosing(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem, case .folder(.local(let url)) = item.location else { return }
        (view.window?.windowController as? MainWindowController)?.reveal(.local(url))
    }

    @objc private func removeItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem else { return }
        if let host = item.host {
            SSHManager.shared.removeFromSidebar(host.destination)
        } else if case .folder(.local(let url)) = item.location {
            Prefs.shared.favorites.removeAll { $0 == url.path }
        }
    }
}

let SSHHostDisconnected = Notification.Name("ScoutSSHHostDisconnected")

final class SidebarOutlineView: NSOutlineView {
    var onDragExit: (() -> Void)?

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragExit?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        onDragExit?()
    }
}

final class SidebarCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let ejectButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let tagDot = TagDotView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ejectButton.translatesAutoresizingMaskIntoConstraints = false
        ejectButton.isBordered = false
        ejectButton.image = Symbols.image("eject.fill", size: 11)
        ejectButton.contentTintColor = .secondaryLabelColor
        ejectButton.setButtonType(.momentaryChange)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        tagDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        addSubview(ejectButton)
        addSubview(spinner)
        addSubview(tagDot)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 20),
            tagDot.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            tagDot.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            tagDot.widthAnchor.constraint(equalToConstant: 12),
            tagDot.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: ejectButton.leadingAnchor, constant: -4),
            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectButton.widthAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: ejectButton.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: SidebarItem, target: SidebarViewController) {
        label.stringValue = item.title
        if let color = item.tagColor {
            icon.image = nil
            tagDot.isHidden = false
            tagDot.color = color
        } else {
            tagDot.isHidden = true
            icon.image = item.symbol.flatMap { Symbols.image($0, size: 15) }
            icon.contentTintColor = item.accent ? .controlAccentColor : .secondaryLabelColor
        }
        ejectButton.isHidden = !item.isEjectable
        ejectButton.target = target
        ejectButton.action = #selector(SidebarViewController.eject(_:))
        if item.host?.state == .connecting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        toolTip = item.host?.entry?.subtitle ?? item.location?.ref?.path
        if let host = item.host, case .failed(let message) = host.state { toolTip = message }
    }
}

final class TagDotView: NSView {
    var color: NSColor = .systemGray { didSet { needsDisplay = true } }
    var bordered = false
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        color.setFill()
        let path = NSBezierPath(ovalIn: rect)
        path.fill()
        if bordered {
            NSColor.windowBackgroundColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
