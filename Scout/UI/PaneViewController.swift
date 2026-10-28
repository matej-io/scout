import AppKit
import UniformTypeIdentifiers

protocol PaneDelegate: AnyObject {
    func paneDidChangeLocation(_ pane: PaneViewController)
    func paneDidChangeSelection(_ pane: PaneViewController)
    func paneDidChangeViewMode(_ pane: PaneViewController)
    func otherPane(of pane: PaneViewController) -> PaneViewController?
}

/// A single file listing: location, history, view style, path bar and status bar.
final class PaneViewController: NSViewController, NSMenuDelegate {
    weak var delegate: PaneDelegate?

    private(set) var location: Location
    private var backStack: [Location] = []
    private var forwardStack: [Location] = []
    /// The folder before this one, for `cd -` in Go to Folder.
    var previousLocation: Location? { backStack.last }
    private(set) var items: [FileItem] = []
    private var rawItems: [FileItem] = []
    private(set) var viewMode: ViewMode
    private(set) var sortKey: SortKey = .name
    private(set) var ascending = true
    private(set) var searchQuery: String?
    private(set) var isLoading = false
    private(set) var loadError: String?

    var isActive = false { didSet { updateIndicator() } }
    var showsIndicator = false { didSet { updateIndicator() } }

    private(set) var content: BrowserContent!
    private let contentContainer = NSView()
    private let indicator = NSView()
    let statusBar = StatusBarView()
    let pathBar = PathBarView()
    private let messageView = PaneMessageView()
    private var airDropView: AirDropView?
    private var watcher: DirectoryWatcher?
    private var loadToken = 0
    private var availableSpace: Int64?
    private var spinnerWork: DispatchWorkItem?

    init(location: Location) {
        self.location = location
        self.viewMode = Prefs.shared.viewMode(for: location.settingsRef)
        let sort = Prefs.shared.sort(for: location.settingsRef)
        self.sortKey = sort.key
        self.ascending = sort.ascending
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = PaneRootView()
        root.pane = self
        view = root

        for v in [contentContainer, pathBar, statusBar, indicator, messageView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        indicator.wantsLayer = true
        indicator.isHidden = true

        pathBar.onNavigate = { [weak self] ref in self?.navigate(to: .folder(ref)) }
        statusBar.onIconSizeChange = { [weak self] size in
            Prefs.shared.iconSize = size
            self?.content.iconSizeChanged()
            NotificationCenter.default.post(name: PaneViewController.iconSizeChanged, object: self)
        }

        pathBarHeight = pathBar.heightAnchor.constraint(equalToConstant: 0)
        statusBarHeight = statusBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: pathBar.topAnchor),

            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathBar.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            pathBarHeight,

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBarHeight,

            indicator.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            indicator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            indicator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            indicator.heightAnchor.constraint(equalToConstant: 2),

            messageView.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            messageView.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            messageView.widthAnchor.constraint(lessThanOrEqualTo: contentContainer.widthAnchor, constant: -40),
        ])
        messageView.isHidden = true

        installContent()
        updateBars()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(prefsChanged), name: Prefs.changed, object: nil)
        nc.addObserver(self, selector: #selector(folderChanged(_:)), name: FileService.folderChanged, object: nil)
        nc.addObserver(self, selector: #selector(activityChanged), name: Activity.changed, object: nil)
        nc.addObserver(self, selector: #selector(hostDisconnected(_:)), name: SSHHostDisconnected, object: nil)
        nc.addObserver(self, selector: #selector(networkChanged), name: NetworkBrowser.changed, object: nil)
        nc.addObserver(self, selector: #selector(networkChanged), name: SSHManager.hostsChanged, object: nil)
        nc.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification, object: nil)
        nc.addObserver(self, selector: #selector(otherPaneIconSize(_:)), name: PaneViewController.iconSizeChanged, object: nil)
    }

    static let iconSizeChanged = Notification.Name("ScoutIconSizeChanged")
    private var pathBarHeight: NSLayoutConstraint!
    private var statusBarHeight: NSLayoutConstraint!

    override func viewDidAppear() {
        super.viewDidAppear()
        if rawItems.isEmpty && !isLoading && loadError == nil { start() }
    }

    private var started = false
    func start() {
        guard !started else { return }
        started = true
        navigate(to: location, recordHistory: false, force: true)
    }

    // MARK: Content

    private func installContent() {
        content?.view.removeFromSuperview()
        content?.removeFromParent()
        let newContent: BrowserContent
        switch viewMode {
        case .icon: newContent = IconContentController()
        case .list: newContent = ListContentController()
        case .column: newContent = ColumnContentController()
        case .gallery: newContent = GalleryContentController()
        }
        newContent.pane = self
        addChild(newContent)
        newContent.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(newContent.view)
        NSLayoutConstraint.activate([
            newContent.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            newContent.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            newContent.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            newContent.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        content = newContent
        statusBar.showsSlider = viewMode == .icon
    }

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        let selection = selectedItems.map(\.ref)
        let hadFocus = isFocused
        viewMode = mode
        Prefs.shared.setViewMode(mode, for: location.settingsRef)
        installContent()
        content.display(items, select: selection)
        if hadFocus { focus() }
        delegate?.paneDidChangeViewMode(self)
        updateStatus()
    }

    var selectedItems: [FileItem] { content?.selectedItems ?? [] }

    var targetFolder: ItemRef? { content?.targetFolder ?? location.ref }

    var isFocused: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    func focus() {
        view.window?.makeFirstResponder(content.focusView)
    }

    // MARK: Navigation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func navigate(to newLocation: Location, recordHistory: Bool = true, select: [ItemRef] = [], force: Bool = false) {
        // Host roots resolve to the remote home folder once connected.
        if case .folder(.remote(let hostName, let path)) = newLocation, path.isEmpty {
            let host = SSHManager.shared.host(hostName)
            if host.isConnected {
                navigate(to: .folder(.remote(host: hostName, path: host.home)), recordHistory: recordHistory, select: select, force: force)
                return
            }
            loadToken += 1
            let token = loadToken
            showMessage("Connecting to “\(host.displayName)”…", spinner: true)
            host.connect { [weak self] result in
                guard let self, token == self.loadToken else { return }
                switch result {
                case .success:
                    self.navigate(to: .folder(.remote(host: hostName, path: host.home)), recordHistory: recordHistory, select: select, force: true)
                case .failure(let error):
                    self.showMessage("Connection failed\n\n" + error.localizedDescription, spinner: false)
                    self.loadError = error.localizedDescription
                }
            }
            return
        }

        if !force && newLocation == location && searchQuery == nil { if !select.isEmpty { content.select(select) }; return }
        if recordHistory && newLocation != location {
            backStack.append(location)
            forwardStack.removeAll()
        }
        let modeChanged = applyFolderSettings(for: newLocation)
        location = newLocation
        searchQuery = nil
        rawItems = []
        items = []
        if modeChanged { installContent() }
        content.display([], select: nil)
        startWatching()
        updateSpecialViews()
        reload(select: select)
        refreshAvailableSpace()
        updatePathBar()
        delegate?.paneDidChangeLocation(self)
    }

    /// Each folder remembers its own view style and sort order, like Finder.
    private func applyFolderSettings(for newLocation: Location) -> Bool {
        let mode = Prefs.shared.viewMode(for: newLocation.settingsRef)
        let sort = Prefs.shared.sort(for: newLocation.settingsRef)
        sortKey = sort.key
        ascending = sort.ascending
        // Column view keeps its style while drilling down, like Finder.
        guard viewMode != .column else { return false }
        if mode != viewMode {
            viewMode = mode
            delegate?.paneDidChangeViewMode(self)
            return true
        }
        return false
    }

    // MARK: Spring-loading

    private var springOrigin: (location: Location, back: [Location], forward: [Location], started: Date)?
    private var springWatch: Timer?

    /// Opens a folder while something is being dragged. If the drag ends without a drop,
    /// the pane springs back to where it was, like Finder.
    func springOpen(_ target: Location) {
        guard target != location else { return }
        if springOrigin == nil {
            springOrigin = (location, backStack, forwardStack, Date())
            let watch = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkSpringEnded() }
            RunLoop.main.add(watch, forMode: .common)
            springWatch = watch
        }
        navigate(to: target)
    }

    private func checkSpringEnded() {
        guard NSEvent.pressedMouseButtons & 1 == 0, let origin = springOrigin else { return }
        springWatch?.invalidate()
        springWatch = nil
        springOrigin = nil
        let dropped = DragSupport.lastDrop > origin.started
        guard !dropped else { return }
        navigate(to: origin.location, recordHistory: false)
        backStack = origin.back
        forwardStack = origin.forward
        delegate?.paneDidChangeLocation(self)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        let current = location
        forwardStack.append(current)
        navigate(to: previous, recordHistory: false, select: current.ref.map { [$0] } ?? [])
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        navigate(to: next, recordHistory: false)
    }

    func goUp() {
        guard let parent = location.parent else { return }
        navigate(to: parent, select: location.ref.map { [$0] } ?? [])
    }

    // MARK: Loading

    func reload(select: [ItemRef]? = nil) {
        loadToken += 1
        let token = loadToken
        let keepSelection = select?.isEmpty == false ? select : selectedItems.map(\.ref)
        isLoading = true
        loadError = nil
        spinnerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isLoading, token == self.loadToken else { return }
            self.showMessage(nil, spinner: true)
        }
        spinnerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)

        let handle: (Result<[FileItem], Error>) -> Void = { [weak self] result in
            guard let self, token == self.loadToken else { return }
            self.isLoading = false
            self.spinnerWork?.cancel()
            switch result {
            case .success(let items):
                self.rawItems = items
                self.items = self.sorted(items)
                self.hideMessage()
                self.content.display(self.items, select: keepSelection)
                if self.items.isEmpty, self.searchQuery != nil { self.showMessage("No Results", spinner: false) }
            case .failure(let error):
                self.rawItems = []
                self.items = []
                self.loadError = error.localizedDescription
                self.content.display([], select: nil)
                self.showMessage(PaneViewController.describe(error), spinner: false)
            }
            self.updateStatus()
            self.delegate?.paneDidChangeSelection(self)
        }

        if let query = searchQuery, !query.isEmpty {
            FileService.search(query, in: location, showHidden: Prefs.shared.showHidden, completion: handle)
        } else {
            FileService.list(location, showHidden: Prefs.shared.showHidden, completion: handle)
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoPermissionError || ns.code == 257) {
            return "You don’t have permission to see this folder’s contents.\n\nGive Scout Full Disk Access in System Settings › Privacy & Security to browse protected folders."
        }
        return error.localizedDescription
    }

    func setSort(_ key: SortKey, ascending: Bool) {
        sortKey = key
        self.ascending = ascending
        Prefs.shared.setSort(key, ascending: ascending, for: location.settingsRef)
        items = sorted(rawItems)
        content.display(items, select: selectedItems.map(\.ref))
        delegate?.paneDidChangeViewMode(self)
    }

    func sorted(_ list: [FileItem]) -> [FileItem] {
        let key = sortKey
        let asc = ascending
        let foldersFirst = Prefs.shared.foldersFirst
        func nameOrder(_ a: FileItem, _ b: FileItem) -> Bool {
            a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
        return list.sorted { a, b in
            if foldersFirst && a.isBrowsable != b.isBrowsable { return a.isBrowsable }
            var result: ComparisonResult
            switch key {
            case .none, .name, .application:
                result = a.displayName.localizedStandardCompare(b.displayName)
            case .kind:
                result = a.kind.localizedStandardCompare(b.kind)
            case .modified:
                result = PaneViewController.compare(a.modified, b.modified)
            case .created:
                result = PaneViewController.compare(a.created, b.created)
            case .lastOpened:
                result = PaneViewController.compare(a.lastOpened, b.lastOpened)
            case .added:
                result = PaneViewController.compare(a.added, b.added)
            case .size:
                result = PaneViewController.compare(a.size ?? -1, b.size ?? -1)
            case .tags:
                result = (a.tags.first ?? "~").localizedStandardCompare(b.tags.first ?? "~")
            }
            if result == .orderedSame { return nameOrder(a, b) }
            // Dates and sizes default to newest/largest first in Finder.
            let descendingByDefault = [.modified, .created, .lastOpened, .added, .size].contains(key)
            let ascendingResult = result == .orderedAscending
            return (asc != descendingByDefault) ? ascendingResult : !ascendingResult
        }
    }

    private static func compare<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        switch (a, b) {
        case let (x?, y?): return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case (nil, _?): return .orderedAscending
        case (_?, nil): return .orderedDescending
        default: return .orderedSame
        }
    }

    private func startWatching() {
        watcher = nil
        if case .folder(.local(let url)) = location, url.isFileURL {
            watcher = DirectoryWatcher(url: url) { [weak self] in
                guard let self, self.searchQuery == nil else { return }
                self.reload()
            }
        }
    }

    @objc private func folderChanged(_ note: Notification) {
        guard let folders = note.userInfo?["folders"] as? [ItemRef] else { return }
        for folder in folders {
            if folder == location.ref {
                // Local folders are already watched; remote ones need a refresh.
                if location.isRemote || watcher == nil { reload() }
            } else {
                content.childrenChanged(in: folder)
            }
        }
    }

    @objc private func prefsChanged() {
        updateBars()
        let hidden = Prefs.shared.showHidden
        if hidden != lastShowHidden {
            lastShowHidden = hidden
            reload()
        }
    }
    private lazy var lastShowHidden = Prefs.shared.showHidden

    @objc private func networkChanged() {
        if location == .network { reload() }
    }

    @objc private func hostDisconnected(_ note: Notification) {
        guard let destination = note.object as? String, location.ref?.remoteHost == destination else { return }
        backStack.removeAll { $0.ref?.remoteHost == destination }
        forwardStack.removeAll { $0.ref?.remoteHost == destination }
        navigate(to: .network, recordHistory: false)
    }

    @objc private func windowKeyChanged() { updateIndicator() }

    @objc private func otherPaneIconSize(_ note: Notification) {
        guard (note.object as AnyObject?) !== self else { return }
        statusBar.iconSize = Prefs.shared.iconSize
        if viewMode == .icon { content.iconSizeChanged() }
    }

    // MARK: Search

    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        searchQuery = trimmed.isEmpty ? nil : trimmed
        reload()
        delegate?.paneDidChangeLocation(self)
    }

    var displayTitle: String {
        if searchQuery != nil { return "Searching “\(location.title)”" }
        return location.title
    }

    // MARK: Status / bars

    private func updateBars() {
        pathBar.isHidden = !Prefs.shared.showPathBar
        pathBarHeight.constant = Prefs.shared.showPathBar ? 26 : 0
        statusBar.isHidden = !Prefs.shared.showStatusBar
        statusBarHeight.constant = Prefs.shared.showStatusBar ? 28 : 0
        statusBar.iconSize = Prefs.shared.iconSize
    }

    private func refreshAvailableSpace() {
        availableSpace = nil
        let current = location
        FileService.availableSpace(for: location) { [weak self] space in
            guard let self, self.location == current else { return }
            self.availableSpace = space
            self.updateStatus()
        }
    }

    func selectionDidChange() {
        updateStatus()
        updatePathBar()
        delegate?.paneDidChangeSelection(self)
    }

    @objc private func activityChanged() { updateStatus() }

    func updateStatus() {
        let count = items.count
        let selected = selectedItems.count
        var text: String
        if location == .airdrop {
            text = ""
        } else if selected > 0 {
            text = "\(selected) of \(count) selected"
        } else {
            text = count == 1 ? "1 item" : "\(count) items"
        }
        if let availableSpace, !text.isEmpty, location.ref != nil, searchQuery == nil {
            text += ", " + Fmt.available(availableSpace) + " available"
        }
        statusBar.text = text
        statusBar.activity = Activity.shared.current
    }

    private func updatePathBar() {
        var ref = location.ref
        if selectedItems.count == 1 { ref = selectedItems[0].ref }
        pathBar.show(ref, fallbackTitle: location.title)
    }

    private func updateIndicator() {
        indicator.isHidden = !(showsIndicator && isActive)
        let keyWindow = view.window?.isKeyWindow ?? true
        indicator.layer?.backgroundColor = (keyWindow ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.45)).cgColor
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateIndicator()
    }

    // MARK: Messages

    private func showMessage(_ text: String?, spinner: Bool) {
        messageView.isHidden = false
        messageView.set(text: text, spinner: spinner)
    }

    private func hideMessage() { messageView.isHidden = true }

    private func updateSpecialViews() {
        if location == .airdrop {
            if airDropView == nil {
                let v = AirDropView()
                v.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(v, positioned: .below, relativeTo: indicator)
                NSLayoutConstraint.activate([
                    v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                    v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                    v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                    v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
                ])
                airDropView = v
            }
            contentContainer.isHidden = true
        } else {
            airDropView?.removeFromSuperview()
            airDropView = nil
            contentContainer.isHidden = false
        }
    }

    // MARK: Opening

    func open(_ targets: [FileItem], newTab: Bool = false) {
        for item in targets {
            if case .local(let url) = item.ref, !url.isFileURL {
                if url.absoluteString == "scout:network" { navigate(to: .network) } else { NSWorkspace.shared.open(url) }
                continue
            }
            if item.isBrowsable || (item.isAlias && resolvedAliasFolder(item) != nil) {
                let target: Location = .folder(item.isAlias ? resolvedAliasFolder(item)! : item.ref)
                if newTab || targets.count > 1 {
                    (view.window?.windowController as? MainWindowController)?.openInNewTab(target)
                } else {
                    navigate(to: target)
                }
                continue
            }
            switch item.ref {
            case .local(let url):
                NSWorkspace.shared.open(url)
            case .remote:
                FileOps.cachedCopy(of: item.ref) { result in
                    switch result {
                    case .success(let url): NSWorkspace.shared.open(url)
                    case .failure(let error): NSAlert(error: error).runModal()
                    }
                }
            }
        }
    }

    private func resolvedAliasFolder(_ item: FileItem) -> ItemRef? {
        guard case .local(let url) = item.ref,
              let resolved = try? URL(resolvingAliasFileAt: url),
              (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return .local(resolved)
    }

    func rename(_ item: FileItem, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name, !name.contains("/") else { return }
        let oldName = item.name
        FileOps.rename(item.ref, to: name) { [weak self] result in
            switch result {
            case .success(let newRef):
                self?.pendingSelection = [newRef]
                self?.reload(select: [newRef])
                if let undo = self?.view.window?.undoManager, case .local = newRef {
                    undo.registerUndo(withTarget: self!) { pane in
                        FileOps.rename(newRef, to: oldName) { _ in pane.reload(select: [item.ref]) }
                    }
                    undo.setActionName("Rename")
                }
            case .failure(let error):
                self?.showError(error)
                self?.content.display(self?.items ?? [], select: [item.ref])
            }
        }
    }

    private var pendingSelection: [ItemRef] = []

    func showError(_ error: Error) {
        guard let window = view.window else { NSAlert(error: error).runModal(); return }
        let alert = NSAlert()
        alert.messageText = "The operation can’t be completed."
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // MARK: Actions (responder chain)

    @objc func openSelection(_ sender: Any?) {
        open(selectedItems)
    }

    @objc func openInNewTab(_ sender: Any?) {
        open(selectedItems.filter(\.isBrowsable), newTab: true)
    }

    @objc func goBack(_ sender: Any?) { goBack() }
    @objc func goForward(_ sender: Any?) { goForward() }
    @objc func goEnclosingFolder(_ sender: Any?) { goUp() }

    @objc func newFolder(_ sender: Any?) {
        guard let folder = targetFolder else { NSSound.beep(); return }
        FileOps.newFolder(in: folder) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let ref):
                if folder == self.location.ref {
                    self.reloadThenRename(ref)
                } else {
                    self.content.childrenChanged(in: folder)
                }
                if let undo = self.view.window?.undoManager, case .local(let url) = ref {
                    undo.registerUndo(withTarget: self) { _ in FileOps.trash([url]) { _, _ in } }
                    undo.setActionName("New Folder")
                }
            case .failure(let error):
                self.showError(error)
            }
        }
    }

    private func reloadThenRename(_ ref: ItemRef) {
        loadToken += 1
        let token = loadToken
        FileService.list(location, showHidden: Prefs.shared.showHidden) { [weak self] result in
            guard let self, token == self.loadToken, case .success(let list) = result else { return }
            self.rawItems = list
            self.items = self.sorted(list)
            self.content.display(self.items, select: [ref])
            self.updateStatus()
            DispatchQueue.main.async { self.content.beginRename(ref) }
        }
    }

    @objc func renameSelection(_ sender: Any?) {
        guard selectedItems.count == 1, let item = selectedItems.first, canModify(item) else { NSSound.beep(); return }
        content.beginRename(item.ref)
    }

    /// Asks for a new name in a sheet (used by views without inline editing).
    func promptRename(_ item: FileItem) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(item.name)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: item.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.rename(item, to: field.stringValue) }
        }
        let ext = (item.name as NSString).pathExtension
        if !ext.isEmpty && !item.isDirectory, let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: (item.name as NSString).length - ext.count - 1)
        }
    }

    private func canModify(_ item: FileItem) -> Bool {
        if case .local(let url) = item.ref { return url.isFileURL }
        if case .remote(_, let path) = item.ref { return !path.isEmpty }
        return false
    }

    @objc func moveToTrash(_ sender: Any?) {
        let targets = selectedItems.filter(canModify)
        guard !targets.isEmpty else { NSSound.beep(); return }
        let remote = targets.filter { $0.ref.isRemote }
        let local = targets.compactMap { $0.ref.localURL }
        if !local.isEmpty {
            FileOps.trash(local) { [weak self] trashed, error in
                if let error { self?.showError(error); return }
                Self.playTrashSound()
                guard let undo = self?.view.window?.undoManager, !trashed.isEmpty else { return }
                undo.registerUndo(withTarget: NSApp) { _ in
                    for (original, inTrash) in trashed { try? FileManager.default.moveItem(at: inTrash, to: original) }
                    FileService.notifyChanged(trashed.keys.map { .local($0.deletingLastPathComponent()) })
                }
                undo.setActionName("Move to \(Prefs.trashTitle)")
            }
        }
        if !remote.isEmpty { confirmRemoteDelete(remote) }
    }

    private static func playTrashSound() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }

    private func confirmRemoteDelete(_ targets: [FileItem]) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = targets.count == 1
            ? "Are you sure you want to delete “\(targets[0].name)”?"
            : "Are you sure you want to delete these \(targets.count) items?"
        alert.informativeText = "This item is on “\(SSHManager.shared.host(targets[0].ref.remoteHost ?? "").displayName)” and will be deleted immediately. You can’t undo this action."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            FileOps.deleteRemote(targets.map(\.ref)) { error in
                if let error { self?.showError(error) }
            }
        }
    }

    @objc func duplicateItems(_ sender: Any?) {
        let targets = selectedItems.filter(canModify)
        guard !targets.isEmpty else { return }
        FileOps.duplicate(targets) { [weak self] result in
            switch result {
            case .success(let refs): self?.reload(select: refs)
            case .failure(let error): self?.showError(error)
            }
        }
    }

    @objc func makeAlias(_ sender: Any?) {
        let targets = selectedItems.filter { !$0.ref.isRemote }
        guard !targets.isEmpty else { return }
        FileOps.makeAlias(targets) { [weak self] result in
            if case .success(let refs) = result { self?.reload(select: refs) }
            if case .failure(let error) = result { self?.showError(error) }
        }
    }

    @objc func compressItems(_ sender: Any?) {
        let targets = selectedItems.filter(canModify)
        guard !targets.isEmpty else { return }
        FileOps.compress(targets) { [weak self] result in
            if case .success(let ref) = result { self?.reload(select: [ref]) }
            if case .failure(let error) = result { self?.showError(error) }
        }
    }

    @objc func copy(_ sender: Any?) {
        guard !selectedItems.isEmpty else { return }
        Clipboard.write(selectedItems)
    }

    @objc func paste(_ sender: Any?) {
        pasteItems(move: false)
    }

    @objc func moveItemsHere(_ sender: Any?) {
        pasteItems(move: true)
    }

    private func pasteItems(move: Bool) {
        let refs = Clipboard.refs
        guard let folder = targetFolder, !refs.isEmpty else { NSSound.beep(); return }
        FileOps.transfer(refs, to: folder, move: move, window: view.window) { [weak self] created in
            if folder == self?.location.ref { self?.reload(select: created) }
        }
        if move { NSPasteboard.general.clearContents() }
    }

    @objc func copyToOtherPane(_ sender: Any?) { sendToOtherPane(move: false) }
    @objc func moveToOtherPane(_ sender: Any?) { sendToOtherPane(move: true) }

    private func sendToOtherPane(move: Bool) {
        guard let other = delegate?.otherPane(of: self), let folder = other.targetFolder else { NSSound.beep(); return }
        let refs = selectedItems.filter(canModify).map(\.ref)
        guard !refs.isEmpty else { NSSound.beep(); return }
        FileOps.transfer(refs, to: folder, move: move, window: view.window) { created in
            if folder == other.location.ref { other.reload(select: created) }
        }
    }

    @objc func copyPathname(_ sender: Any?) {
        let paths = selectedItems.map { item -> String in
            if case .remote(let host, let path) = item.ref { return "\(host):\(path)" }
            return item.ref.path
        }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func showInEnclosingFolder(_ sender: Any?) {
        guard let item = selectedItems.first, let parent = item.ref.parent else { return }
        navigate(to: .folder(parent), select: [item.ref])
    }

    @objc func openInTerminal(_ sender: Any?) {
        let ref = selectedItems.first(where: \.isBrowsable)?.ref ?? targetFolder
        if let ref { Terminal.open(ref) }
    }

    @objc func getInfo(_ sender: Any?) {
        let targets = selectedItems.isEmpty ? [currentFolderItem()].compactMap { $0 } : selectedItems
        for item in targets.prefix(10) { InfoPanelController.show(item) }
    }

    private func currentFolderItem() -> FileItem? {
        guard let ref = location.ref else { return nil }
        if case .local(let url) = ref { return FileItem.local(url) }
        return FileItem(ref: ref, name: ref.name, isDirectory: true, isHidden: false, size: nil, modified: nil, kind: "Folder")
    }

    @objc func setViewModeFromMenu(_ sender: NSMenuItem) {
        if let mode = ViewMode(rawValue: sender.tag) { setViewMode(mode) }
    }

    @objc func sortByFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = SortKey(rawValue: raw) else { return }
        if key == sortKey { setSort(key, ascending: !ascending) } else { setSort(key, ascending: true) }
    }

    @objc func openWithApplication(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        let targets = selectedItems
        let localURLs = targets.compactMap { $0.ref.localURL }
        if !localURLs.isEmpty {
            NSWorkspace.shared.open(localURLs, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
        for item in targets where item.ref.isRemote {
            FileOps.cachedCopy(of: item.ref) { result in
                if case .success(let url) = result {
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
    }

    @objc func chooseOtherApplication(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let app = panel.url else { return }
            let item = NSMenuItem()
            item.representedObject = app
            self?.openWithApplication(item)
        }
    }

    func setTag(_ tag: String, on items: [FileItem]) {
        let urls = items.compactMap { $0.ref.localURL }
        guard !urls.isEmpty else { return }
        let allHave = items.allSatisfy { $0.tags.contains(tag) }
        for url in urls {
            var tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            if allHave { tags.removeAll { $0 == tag } } else if !tags.contains(tag) { tags.append(tag) }
            try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        reload()
    }

    @objc func ejectHost(_ sender: Any?) {
        guard let host = location.ref?.remoteHost else { return }
        SSHManager.shared.host(host).disconnect()
        NotificationCenter.default.post(name: SSHHostDisconnected, object: host)
    }

    func validate(_ item: NSMenuItem) -> Bool {
        let selection = selectedItems
        let modifiable = selection.filter(canModify)
        switch item.action {
        case #selector(openSelection(_:)):
            return !selection.isEmpty
        case #selector(openInNewTab(_:)):
            return selection.contains(where: \.isBrowsable)
        case #selector(goBack(_:)): return canGoBack
        case #selector(goForward(_:)): return canGoForward
        case #selector(goEnclosingFolder(_:)): return location.parent != nil
        case #selector(newFolder(_:)): return targetFolder != nil && searchQuery == nil
        case #selector(renameSelection(_:)): return modifiable.count == 1
        case #selector(moveToTrash(_:)):
            if modifiable.contains(where: { $0.ref.isRemote }) { item.title = "Delete Immediately…" }
            else { item.title = "Move to \(Prefs.trashTitle)" }
            return !modifiable.isEmpty
        case #selector(duplicateItems(_:)), #selector(compressItems(_:)):
            if item.action == #selector(compressItems(_:)) {
                item.title = modifiable.count == 1 ? "Compress “\(modifiable[0].name)”" : (modifiable.isEmpty ? "Compress" : "Compress \(modifiable.count) Items")
            }
            return !modifiable.isEmpty
        case #selector(makeAlias(_:)): return selection.contains { !$0.ref.isRemote }
        case #selector(copy(_:)):
            item.title = selection.count == 1 ? "Copy “\(selection[0].displayName)”" : (selection.isEmpty ? "Copy" : "Copy \(selection.count) Items")
            return !selection.isEmpty
        case #selector(paste(_:)), #selector(moveItemsHere(_:)):
            let refs = Clipboard.refs
            let noun = refs.count == 1 ? "Item" : "Items"
            item.title = item.action == #selector(paste(_:)) ? "Paste \(noun)" : "Move \(noun) Here"
            return !refs.isEmpty && targetFolder != nil
        case #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)):
            return delegate?.otherPane(of: self) != nil && !modifiable.isEmpty
        case #selector(copyPathname(_:)): return !selection.isEmpty
        case #selector(showInEnclosingFolder(_:)): return selection.count == 1 && (searchQuery != nil || location.ref == nil)
        case #selector(setViewModeFromMenu(_:)):
            item.state = item.tag == viewMode.rawValue ? .on : .off
            return true
        case #selector(sortByFromMenu(_:)):
            item.state = (item.representedObject as? String) == sortKey.rawValue ? .on : .off
            return true
        case #selector(ejectHost(_:)):
            return location.isRemote
        default:
            return true
        }
    }

    // MARK: Context menus

    func contextMenu(for selection: [FileItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        guard !selection.isEmpty else { return backgroundMenu() }
        let single = selection.count == 1 ? selection[0] : nil

        menu.addItem(withTitle: "Open", action: #selector(openSelection(_:)), keyEquivalent: "")
        if selection.contains(where: { !$0.isBrowsable }) {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = openWithMenu(for: selection)
            menu.addItem(openWith)
        }
        if selection.contains(where: \.isBrowsable) {
            menu.addItem(withTitle: "Open in New Tab", action: #selector(openInNewTab(_:)), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to \(Prefs.trashTitle)", action: #selector(moveToTrash(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Get Info", action: #selector(getInfo(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Rename", action: #selector(renameSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Compress", action: #selector(compressItems(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicateItems(_:)), keyEquivalent: "")
        if !selection.contains(where: { $0.ref.isRemote }) {
            menu.addItem(withTitle: "Make Alias", action: #selector(makeAlias(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: single.map { "Quick Look “\($0.displayName)”" } ?? "Quick Look", action: #selector(MainWindowController.togglePreviewPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        if delegate?.otherPane(of: self) != nil {
            menu.addItem(withTitle: "Copy to Other Pane", action: #selector(copyToOtherPane(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Move to Other Pane", action: #selector(moveToOtherPane(_:)), keyEquivalent: "")
        }
        if !selection.contains(where: { $0.ref.isRemote }) {
            let share = NSMenuItem(title: "Share…", action: #selector(MainWindowController.shareSelection(_:)), keyEquivalent: "")
            menu.addItem(share)
        }
        menu.addItem(.separator())
        if !selection.contains(where: { $0.ref.isRemote }) {
            let tags = NSMenuItem()
            tags.view = TagMenuView(selection: selection) { [weak self] tag in
                self?.setTag(tag, on: selection)
                menu.cancelTracking()
            }
            menu.addItem(tags)
            menu.addItem(.separator())
        }
        if searchQuery != nil || location.ref == nil {
            menu.addItem(withTitle: "Show in Enclosing Folder", action: #selector(showInEnclosingFolder(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Copy as Pathname", action: #selector(copyPathname(_:)), keyEquivalent: "")
        if selection.contains(where: \.isBrowsable) || location.isRemote {
            menu.addItem(withTitle: "Open in Terminal", action: #selector(openInTerminal(_:)), keyEquivalent: "")
        }
        return menu
    }

    private func backgroundMenu() -> NSMenu {
        let menu = NSMenu()
        if location.isWritableFolder {
            menu.addItem(withTitle: "New Folder", action: #selector(newFolder(_:)), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Get Info", action: #selector(getInfo(_:)), keyEquivalent: "")
        if location.isWritableFolder {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Paste Item", action: #selector(paste(_:)), keyEquivalent: "")
        }
        menu.addItem(.separator())
        let sort = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sort.submenu = PaneViewController.sortMenu()
        menu.addItem(sort)
        let view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu()
        for mode in ViewMode.allCases {
            let mi = NSMenuItem(title: mode.title, action: #selector(setViewModeFromMenu(_:)), keyEquivalent: "")
            mi.tag = mode.rawValue
            viewMenu.addItem(mi)
        }
        view.submenu = viewMenu
        menu.addItem(view)
        if location.ref != nil {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Open in Terminal", action: #selector(openInTerminal(_:)), keyEquivalent: "")
        }
        if location.isRemote {
            menu.addItem(withTitle: "Disconnect", action: #selector(ejectHost(_:)), keyEquivalent: "")
        }
        return menu
    }

    static func sortMenu() -> NSMenu {
        let menu = NSMenu()
        for key in SortKey.menuOrder {
            let mi = NSMenuItem(title: key.title, action: #selector(PaneViewController.sortByFromMenu(_:)), keyEquivalent: "")
            mi.representedObject = key.rawValue
            menu.addItem(mi)
        }
        return menu
    }

    private func openWithMenu(for selection: [FileItem]) -> NSMenu {
        let menu = NSMenu()
        var apps: [URL] = []
        var defaultApp: URL?
        if let item = selection.first {
            switch item.ref {
            case .local(let url):
                apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
                defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
            case .remote(_, let path):
                let ext = (path as NSString).pathExtension
                let type = UTType(filenameExtension: ext) ?? .data
                apps = NSWorkspace.shared.urlsForApplications(toOpen: type)
                defaultApp = NSWorkspace.shared.urlForApplication(toOpen: type)
            }
        }
        func add(_ app: URL, isDefault: Bool) {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            let mi = NSMenuItem(title: isDefault ? "\(name) (default)" : name, action: #selector(openWithApplication(_:)), keyEquivalent: "")
            mi.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            mi.image = icon
            mi.target = self
            menu.addItem(mi)
        }
        if let defaultApp {
            add(defaultApp, isDefault: true)
            menu.addItem(.separator())
        }
        for app in apps where app != defaultApp {
            add(app, isDefault: false)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Other…", action: #selector(chooseOtherApplication(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        return menu
    }
}

extension PaneViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { validate(menuItem) }
}

/// Root view of a pane; clicking anywhere inside makes the pane active.
final class PaneRootView: NSView {
    weak var pane: PaneViewController?
}

// MARK: - Message overlay

final class PaneMessageView: NSStackView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        spacing = 10
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13)
        label.isSelectable = true
        spinner.style = .spinning
        spinner.controlSize = .regular
        addArrangedSubview(spinner)
        addArrangedSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(text: String?, spinner showSpinner: Bool) {
        label.stringValue = text ?? ""
        label.isHidden = text == nil
        spinner.isHidden = !showSpinner
        if showSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let clicks reach the file view underneath unless they hit the text.
        let hit = super.hitTest(point)
        return hit === label ? hit : nil
    }
}

// MARK: - Tag picker inside context menus

final class TagMenuView: NSView {
    private let selection: [FileItem]
    private let onPick: (String) -> Void

    init(selection: [FileItem], onPick: @escaping (String) -> Void) {
        self.selection = selection
        self.onPick = onPick
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
        var x: CGFloat = 20
        for tag in FinderTag.all {
            let button = TagDotButton(frame: NSRect(x: x, y: 4, width: 18, height: 18))
            button.color = tag.color
            button.selected = selection.allSatisfy { $0.tags.contains(tag.name) }
            button.toolTip = tag.name
            button.onClick = { [weak self] in self?.onPick(tag.name) }
            addSubview(button)
            x += 26
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class TagDotButton: NSView {
    var color: NSColor = .gray
    var selected = false
    var onClick: (() -> Void)?
    private var hovering = false
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = hovering ? 0.5 : 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        if selected || hovering {
            let symbol = selected && !hovering ? "checkmark" : (selected ? "xmark" : "plus")
            if let image = Symbols.image(symbol, size: 9, weight: .bold) {
                let tinted = image.tinted(.white)
                let size = tinted.size
                tinted.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
            }
        }
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
