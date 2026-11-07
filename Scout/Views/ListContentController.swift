import AppKit

final class FileOutlineView: NSOutlineView {
    weak var pane: PaneViewController?
    var onDragExit: (() -> Void)?
    var onRenameClick: (() -> Void)?
    private let clickRename = ClickRename()

    func cancelPendingRename() { clickRename.cancel() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let column = column(withIdentifier: .init("name"))
        let field = row >= 0 && column >= 0
            ? (view(atColumn: column, row: row, makeIfNecessary: false) as? NameCellView)?.textField : nil
        let eligible = row >= 0 && selectedRowIndexes == IndexSet(integer: row)
            && field.map { !$0.isEditable && $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } == true
        clickRename.mouseDown(event, eligible: eligible) { [weak self] in
            guard let self, self.window?.firstResponder === self,
                  self.selectedRowIndexes == IndexSet(integer: row) else { return }
            self.onRenameClick?()
        }
        super.mouseDown(with: event)
        clickRename.mouseUp(NSApp.currentEvent)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        clickRename.mouseUp(event)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragExit?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // draggingEnded(_:) is optional and NSOutlineView doesn't implement it; an unguarded super call throws.
        if NSOutlineView.instancesRespond(to: #selector(draggingEnded(_:))) { super.draggingEnded(sender) }
        onDragExit?()
    }

    override func keyDown(with event: NSEvent) {
        cancelPendingRename()
        if BrowserKeys.handle(event, pane: pane) { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        cancelPendingRename()
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        } else if row < 0 {
            deselectAll(nil)
        }
        return pane?.contextMenu(for: pane?.selectedItems ?? [])
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move, .generic] : [.copy, .move, .link, .generic, .delete]
    }
}

/// Finder’s list view: sortable columns and disclosure triangles.
final class ListContentController: NSViewController, BrowserContent, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    weak var pane: PaneViewController? { didSet { outline.pane = pane } }
    private let outline = FileOutlineView()
    private let scroll = NSScrollView()
    private var items: [FileItem] = []
    private var expandedRefs = Set<ItemRef>()
    /// The folder and sort order the rows show, so a new listing of it can be applied as changes to the rows.
    private var shown: (location: Location, sortKey: SortKey, ascending: Bool, foldersFirst: Bool)?
    /// How many times the whole outline was rebuilt, for SCOUT_REFRESHTEST.
    static var fullReloads = 0
    /// The top-level rows' names, for SCOUT_REFRESHTEST.
    var topLevelNames: [String] { items.map(\.name) }
    private var editingItem: FileItem?
    private var suppressSelectionNotifications = false
    /// True while a drag is over the list; folders then spring open after a delay instead of expanding.
    private var isDragging = false
    private lazy var springLoader = SpringLoader(blink: { [weak self] key, on in
        guard let self, let ref = key.base as? ItemRef, let item = self.findItem(ref) else { return }
        let row = self.outline.row(forItem: item)
        if row >= 0 { self.outline.rowView(atRow: row, makeIfNecessary: false)?.isTargetForDropOperation = on }
    }, open: { [weak self] key in
        guard let ref = key.base as? ItemRef else { return }
        self?.pane?.springOpen(.folder(ref))
    })

    struct Column {
        let id: String
        let title: String
        let width: CGFloat
        let sortKey: SortKey
        let alignment: NSTextAlignment
    }

    static let columns: [Column] = [
        Column(id: "name", title: "Name", width: 280, sortKey: .name, alignment: .left),
        Column(id: "modified", title: "Date Modified", width: 180, sortKey: .modified, alignment: .left),
        Column(id: "created", title: "Date Created", width: 180, sortKey: .created, alignment: .left),
        Column(id: "lastOpened", title: "Date Last Opened", width: 180, sortKey: .lastOpened, alignment: .left),
        Column(id: "added", title: "Date Added", width: 180, sortKey: .added, alignment: .left),
        Column(id: "size", title: "Size", width: 96, sortKey: .size, alignment: .right),
        Column(id: "kind", title: "Kind", width: 130, sortKey: .kind, alignment: .left),
        Column(id: "tags", title: "Tags", width: 90, sortKey: .tags, alignment: .left),
    ]

    static func preferredWidth(_ column: NSTableColumn) -> CGFloat {
        columns.first { $0.id == column.identifier.rawValue }?.width ?? column.width
    }

    static func minimumWidth(_ column: NSTableColumn) -> CGFloat {
        switch column.identifier.rawValue {
        case "size": return 64
        case "kind", "tags": return 70
        default: return 112
        }
    }

    static var visibleColumns: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "listColumns") ?? ["name", "modified", "size", "kind"]) }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "listColumns")
            NotificationCenter.default.post(name: Prefs.viewOptionsChanged, object: nil)
        }
    }

    private static var rowHeight: CGFloat {
        max(Prefs.shared.listIconSize + 4, (Prefs.shared.listTextSize * 1.25).rounded() + 4)
    }

    override func loadView() {
        for column in ListContentController.columns {
            let tc = NSTableColumn(identifier: .init(column.id))
            tc.title = column.title
            tc.width = column.width
            tc.minWidth = column.id == "name" ? 120 : 50
            let newestFirst = [SortKey.modified, .created, .lastOpened, .added, .size].contains(column.sortKey)
            tc.sortDescriptorPrototype = NSSortDescriptor(key: column.sortKey.rawValue, ascending: !newestFirst)
            tc.isHidden = !ListContentController.visibleColumns.contains(column.id)
            tc.resizingMask = [.userResizingMask, .autoresizingMask]
            outline.addTableColumn(tc)
            if column.id == "name" { outline.outlineTableColumn = tc }
        }
        outline.style = .inset
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = true
        outline.allowsTypeSelect = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.rowHeight = ListContentController.rowHeight
        outline.intercellSpacing = NSSize(width: 3, height: 0)
        outline.indentationPerLevel = 16
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.onRenameClick = { [weak self] in self?.pane?.renameSelection(nil) }
        outline.registerForDraggedTypes(DragSupport.types)
        outline.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        outline.draggingDestinationFeedbackStyle = .regular
        outline.onDragExit = { [weak self] in
            self?.isDragging = false
            self?.springLoader.cancel()
        }

        let headerMenu = NSMenu()
        headerMenu.delegate = self
        outline.headerView?.menu = headerMenu

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        view = scroll
        syncSortIndicator()
    }

    var focusView: NSView { outline }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Like Finder, the Name column absorbs width changes so the other columns stay visible.
        // When the pane gets narrow (e.g. split view) the other columns shrink toward their minimum widths too.
        guard let name = outline.tableColumn(withIdentifier: .init("name")) else { return }
        let others = outline.tableColumns.filter { !$0.isHidden && $0 !== name }
        let spacing = outline.intercellSpacing.width * CGFloat(others.count + 1) + 24
        let total = scroll.contentView.bounds.width - spacing
        let preferred = others.reduce(CGFloat(0)) { $0 + ListContentController.preferredWidth($1) }
        let minimum = others.reduce(CGFloat(0)) { $0 + ListContentController.minimumWidth($1) }
        let nameWanted: CGFloat = 170
        if total - preferred >= nameWanted {
            for c in others { c.width = ListContentController.preferredWidth(c) }
            name.width = total - preferred
        } else {
            let room = max(minimum, total - nameWanted)
            let ratio = preferred > minimum ? (room - minimum) / (preferred - minimum) : 0
            for c in others {
                let lo = ListContentController.minimumWidth(c), hi = ListContentController.preferredWidth(c)
                c.width = lo + (hi - lo) * max(0, min(1, ratio))
            }
            name.width = max(name.minWidth, total - others.reduce(CGFloat(0)) { $0 + $1.width })
        }
    }

    private func syncSortIndicator() {
        guard let pane else { return }
        let key = pane.sortKey == .none ? SortKey.name : pane.sortKey
        let descendingByDefault = [.modified, .created, .lastOpened, .added, .size].contains(key)
        outline.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: pane.ascending != descendingByDefault ? true : false)]
    }

    // MARK: BrowserContent

    func display(_ newItems: [FileItem], select refs: [ItemRef]?) {
        show(newItems, select: refs, inPlace: true)
    }

    /// A new listing of the folder already on screen only changes the rows that changed (a new folder, a
    /// deleted file, an updated date). Rebuilding the whole outline instead collapses every expanded folder
    /// and reloads its children, which is what made the list blink after every change on disk.
    private func show(_ newItems: [FileItem], select refs: [ItemRef]?, inPlace: Bool) {
        outline.cancelPendingRename()
        let current = currentShown()
        let sameFolder = current != nil && current?.location == shown?.location
        if inPlace, sameFolder, current! == shown!, !items.isEmpty {
            update(nil, with: newItems, select: refs)
            return
        }
        let scrollOrigin = scroll.contentView.bounds.origin
        let refreshing = pane?.isRefreshingListing == true
        // Search results come from many folders: only their live updates count as the same listing.
        let sameListing = refreshing || sameFolder && !items.isEmpty
        // Search results come and go above the visible rows; keep a row that stays in view where it was.
        let anchor = refreshing ? visibleAnchor() : nil
        if sameFolder {
            // Same folder in a new order (or new view options): keep the loaded children, so expanded
            // folders open again straight away rather than collapsing while they reload.
            var changed: [FileItem] = []
            items = reconcile(newItems, with: items, changed: &changed)
            resortChildren(items)
        } else {
            items = newItems
        }
        shown = current
        ListContentController.fullReloads += 1
        suppressSelectionNotifications = true
        outline.reloadData()
        syncSortIndicator()
        // Re-open folders that were expanded before the refresh.
        let wanted = expandedRefs
        expandedRefs = []
        for item in items where wanted.contains(item.ref) { expand(item, restoring: wanted) }
        if let refs { selectRefs(refs, scroll: !sameListing) }
        if sameListing {
            scroll.contentView.scroll(to: scrollOrigin)
        } else if outline.selectedRowIndexes.isEmpty, outline.numberOfRows > 0 {
            outline.scrollRowToVisible(0)   // a new listing (or new search) starts at the top
        }
        if let anchor, let item = findItem(anchor.ref) {
            let row = outline.row(forItem: item)
            if row >= 0 {
                let clip = scroll.contentView
                let proposed = NSRect(origin: NSPoint(x: scrollOrigin.x, y: outline.rect(ofRow: row).minY - anchor.offset),
                                      size: clip.bounds.size)
                clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        suppressSelectionNotifications = false
        pane?.selectionDidChange()
    }

    /// What the pane shows now; nil for search results, which have their own way of updating.
    private func currentShown() -> (location: Location, sortKey: SortKey, ascending: Bool, foldersFirst: Bool)? {
        guard let pane, pane.searchQuery == nil else { return nil }
        return (pane.location, pane.sortKey, pane.ascending, Prefs.shared.foldersFirst)
    }

    // MARK: In-place updates

    /// Shows a fresh listing of `parent`'s children (nil: the top level) by inserting, removing and moving
    /// just the rows that differ. Rows that stay keep their object, so an expanded folder stays expanded.
    private func update(_ parent: FileItem?, with fresh: [FileItem], select refs: [ItemRef]?) {
        let old = children(of: parent)
        var changed: [FileItem] = []
        let target = reconcile(fresh, with: old, changed: &changed)
        let steps = RowDiff.steps(from: old, to: target)
        // A wholesale reorder is cheaper (and calmer) as one reload than as thousands of row moves.
        if parent == nil, steps.count > 400 {
            show(fresh, select: refs, inPlace: false)
            return
        }

        suppressSelectionNotifications = true
        let removed = Set(old.map(\.ref)).subtracting(target.map(\.ref))
        expandedRefs.subtract(removed)
        if !steps.isEmpty {
            var working = old
            outline.beginUpdates()
            for step in steps {
                // The data source reads `working` as each step runs, so it always matches the rows.
                switch step {
                case .remove(let indexes):
                    for i in indexes.reversed() { working.remove(at: i) }
                    setChildren(working, of: parent)
                    outline.removeItems(at: indexes, inParent: parent, withAnimation: .effectFade)
                case .move(let from, let to):
                    working.insert(working.remove(at: from), at: to)
                    setChildren(working, of: parent)
                    outline.moveItem(at: from, inParent: parent, to: to, inParent: parent)
                case .insert(let index):
                    working.insert(target[index], at: index)
                    setChildren(working, of: parent)
                    outline.insertItems(at: [index], inParent: parent, withAnimation: [])
                }
            }
            outline.endUpdates()
        }
        setChildren(target, of: parent)

        // Rows whose details changed (a folder's date after something went into it) redraw on their own.
        let columns = IndexSet(integersIn: 0..<outline.numberOfColumns)
        let rows = IndexSet(changed.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        if !rows.isEmpty { outline.reloadData(forRowIndexes: rows, columnIndexes: columns) }
        // An expanded folder whose date changed has different contents; catch up on them too.
        for item in changed where item.isBrowsable && outline.isItemExpanded(item) { childrenChanged(in: item.ref) }

        if let refs { selectRefs(refs, scroll: false) }
        suppressSelectionNotifications = false
        pane?.selectionDidChange()
    }

    private func children(of parent: FileItem?) -> [FileItem] {
        parent.map { $0.children ?? [] } ?? items
    }

    private func setChildren(_ list: [FileItem], of parent: FileItem?) {
        if let parent { parent.children = list } else { items = list }
    }

    /// The fresh listing, using the objects already on screen for items still there (updated with fresh
    /// details, listed in `changed` when anything they show changed).
    private func reconcile(_ fresh: [FileItem], with old: [FileItem], changed: inout [FileItem]) -> [FileItem] {
        let existing = Dictionary(old.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        return fresh.map { item in
            guard let kept = existing[item.ref], kept !== item else { return item }
            if kept.update(from: item) { changed.append(kept) }
            return kept
        }
    }

    /// Loaded children follow a change of sort order.
    private func resortChildren(_ list: [FileItem]) {
        guard let pane else { return }
        for item in list {
            guard let children = item.children else { continue }
            item.children = pane.sorted(children)
            resortChildren(item.children ?? [])
        }
    }

    /// A selected row on screen and its distance from the top of the visible area (the one under the mouse,
    /// if several are). Without one, the list keeps its scroll position, so results that arrive while it's
    /// at the top appear at the top rather than pushing the view down.
    private func visibleAnchor() -> (ref: ItemRef, offset: CGFloat)? {
        let visible = scroll.contentView.bounds
        let range = outline.rows(in: visible)
        guard range.length > 0 else { return nil }
        let rows = range.location..<(range.location + range.length)
        var row = rows.first { outline.selectedRowIndexes.contains($0) && visible.contains(NSPoint(x: visible.midX, y: outline.rect(ofRow: $0).midY)) }
        if let window = view.window {
            let mouse = outline.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let hovered = outline.row(at: mouse)
            if outline.selectedRowIndexes.contains(hovered), rows.contains(hovered) { row = hovered }
        }
        guard let row, let item = outline.item(atRow: row) as? FileItem else { return nil }
        return (item.ref, outline.rect(ofRow: row).minY - visible.minY)
    }

    var selectedItems: [FileItem] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileItem }
    }

    func select(_ refs: [ItemRef]) { selectRefs(refs, scroll: true) }

    private func selectRefs(_ refs: [ItemRef], scroll: Bool) {
        let wanted = Set(refs)
        var rows = IndexSet()
        for row in 0..<outline.numberOfRows {
            if let item = outline.item(atRow: row) as? FileItem, wanted.contains(item.ref) { rows.insert(row) }
        }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if scroll, let first = rows.first { outline.scrollRowToVisible(first) }
    }

    func childrenChanged(in folder: ItemRef) {
        guard let item = findItem(folder), outline.isItemExpanded(item) else { return }
        FileService.list(folder, showHidden: Prefs.shared.showHidden) { [weak self] result in
            guard let self, case .success(let children) = result,
                  item.children != nil, self.outline.isItemExpanded(item) else { return }
            self.update(item, with: self.pane?.sorted(children) ?? children, select: nil)
        }
    }

    func revertRename(_ ref: ItemRef) {
        guard let item = findItem(ref) else { return }
        let row = outline.row(forItem: item)
        if row >= 0 { outline.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns)) }
    }

    private func findItem(_ ref: ItemRef) -> FileItem? {
        for row in 0..<outline.numberOfRows {
            if let item = outline.item(atRow: row) as? FileItem, item.ref == ref { return item }
        }
        return nil
    }

    // MARK: Expansion (children load asynchronously, also over SSH)

    private func expand(_ item: FileItem, restoring: Set<ItemRef> = []) {
        if let children = item.children {
            outline.expandItem(item)
            for child in children where restoring.contains(child.ref) { expand(child, restoring: restoring) }
            return
        }
        FileService.list(item.ref, showHidden: Prefs.shared.showHidden) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let children):
                item.children = self.pane?.sorted(children) ?? children
                self.outline.reloadItem(item, reloadChildren: true)
                self.outline.expandItem(item)
                for child in item.children ?? [] where restoring.contains(child.ref) { self.expand(child, restoring: restoring) }
            case .failure:
                item.children = []
                NSSound.beep()
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let item = item as? FileItem else { return false }
        // NSOutlineView expands folders as soon as a drag hovers them; Finder springs them open after a delay instead.
        if isDragging { return false }
        if item.children == nil {
            expand(item)
            return false
        }
        return true
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? FileItem { expandedRefs.insert(item.ref) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? FileItem {
            expandedRefs.remove(item.ref)
            item.children = nil
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? FileItem else { return items.count }
        return item.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? FileItem else { return items[index] }
        return item.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileItem)?.isBrowsable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key.flatMap(SortKey.init(rawValue:)) else { return }
        let descendingByDefault = [.modified, .created, .lastOpened, .added, .size].contains(key)
        let ascending = descendingByDefault ? !descriptor.ascending : descriptor.ascending
        if pane?.sortKey != key || pane?.ascending != ascending {
            pane?.setSort(key, ascending: ascending)
        }
    }

    // MARK: Cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? FileItem, let column = tableColumn else { return nil }
        let id = column.identifier.rawValue
        if id == "name" {
            let cell = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? NameCellView ?? NameCellView(identifier: column.identifier)
            cell.configure(item, iconSize: Prefs.shared.listIconSize, font: .systemFont(ofSize: Prefs.shared.listTextSize),
                           preview: Prefs.shared.listShowPreview)
            cell.textField?.delegate = self
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? TextCellView ?? TextCellView(identifier: column.identifier)
        let text: String
        switch id {
        case "modified": text = Fmt.dateString(item.modified, relative: Prefs.shared.listRelativeDates)
        case "created": text = Fmt.dateString(item.created, relative: Prefs.shared.listRelativeDates)
        case "lastOpened": text = Fmt.dateString(item.lastOpened, relative: Prefs.shared.listRelativeDates)
        case "added": text = Fmt.dateString(item.added, relative: Prefs.shared.listRelativeDates)
        case "size": text = item.isBrowsable ? "--" : Fmt.size(item.size)
        case "kind": text = item.kind
        case "tags": text = item.tags.joined(separator: ", ")
        default: text = ""
        }
        cell.configure(text, alignment: id == "size" ? .right : .left, dimmed: item.isHidden,
                       font: .systemFont(ofSize: Prefs.shared.listTextSize))
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        outline.cancelPendingRename()
        guard !suppressSelectionNotifications else { return }
        pane?.selectionDidChange()
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        tableColumn?.identifier.rawValue == "name" ? (item as? FileItem)?.displayName : nil
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0 else { return }
        pane?.open(selectedItems)
    }

    // MARK: Rename

    var isEditingName: Bool { editingItem != nil }

    func beginRename(_ ref: ItemRef) {
        guard let item = findItem(ref) else { return }
        let row = outline.row(forItem: item)
        let column = outline.column(withIdentifier: .init("name"))
        guard row >= 0, column >= 0,
              let cell = outline.view(atColumn: column, row: row, makeIfNecessary: true) as? NameCellView,
              let field = cell.textField else { return }
        outline.scrollRowToVisible(row)
        editingItem = item
        field.stringValue = item.name
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.isBordered = true
        view.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let ext = (item.name as NSString).pathExtension
            let length = (item.name as NSString).length
            editor.selectedRange = NSRange(location: 0, length: ext.isEmpty || item.isDirectory ? length : length - ext.count - 1)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let item = editingItem {
            (control as? NSTextField)?.stringValue = item.name
            editingItem = nil
            endEditing(control as? NSTextField)
            view.window?.makeFirstResponder(outline)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let item = editingItem
        editingItem = nil
        endEditing(field)
        // Keep showing the typed name until the listing catches up, rather than flashing the old one;
        // a rename that doesn't happen (or fails) puts the old name back.
        if let item, pane?.rename(item, to: field.stringValue) != true {
            field.stringValue = item.displayName
        }
        view.window?.makeFirstResponder(outline)
        pane?.nameEditingEnded()
    }

    private func endEditing(_ field: NSTextField?) {
        field?.isEditable = false
        field?.isSelectable = false
        field?.drawsBackground = false
        field?.isBordered = false
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? FileItem else { return nil }
        return DragSupport.writer(for: item)
    }

    /// Like Finder, drag just the icon and name (on a tinted pill) rather than the whole row with every column.
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        outline.cancelPendingRename()
        let column = outlineView.column(withIdentifier: .init("name"))
        guard column >= 0 else { return }
        session.enumerateDraggingItems(options: [], for: outlineView, classes: [NSPasteboardItem.self], searchOptions: [:]) { [weak self] draggingItem, _, _ in
            guard let self,
                  let data = (draggingItem.item as? NSPasteboardItem)?.data(forType: .scoutRefs),
                  let ref = (try? JSONDecoder().decode([ItemRef].self, from: data))?.first,
                  let item = self.findItem(ref) else { return }
            let row = outlineView.row(forItem: item)
            guard row >= 0, let cell = outlineView.view(atColumn: column, row: row, makeIfNecessary: true) as? NameCellView else { return }
            cell.layoutSubtreeIfNeeded()
            let components = cell.draggingImageComponents
            draggingItem.draggingFrame = outlineView.convert(cell.bounds, from: cell)
            draggingItem.imageComponentsProvider = { components }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        isDragging = true
        if let folder = item as? FileItem, folder.isBrowsable {
            outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
            springLoader.hover(folder.ref)
            return DragSupport.operation(for: info, destination: folder.ref)
        }
        springLoader.hover(nil)
        guard let destination = pane?.location.ref else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return DragSupport.operation(for: info, destination: destination)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        isDragging = false
        springLoader.cancel()
        let destination = (item as? FileItem)?.ref ?? pane?.location.ref
        guard let destination else { return false }
        return DragSupport.accept(info, destination: destination, window: view.window)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == .delete { pane?.moveToTrash(nil) }
    }

    // MARK: Header menu (choose columns)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in ListContentController.columns where column.id != "name" {
            let mi = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = column.id
            mi.state = ListContentController.visibleColumns.contains(column.id) ? .on : .off
            menu.addItem(mi)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let column = outline.tableColumn(withIdentifier: .init(id)) else { return }
        var visible = ListContentController.visibleColumns
        if visible.contains(id) { visible.remove(id) } else { visible.insert(id) }
        ListContentController.visibleColumns = visible
    }

    func viewOptionsChanged() {
        let visible = ListContentController.visibleColumns
        for column in outline.tableColumns where column.identifier.rawValue != "name" {
            column.isHidden = !visible.contains(column.identifier.rawValue)
        }
        outline.rowHeight = ListContentController.rowHeight
        show(items, select: selectedItems.map(\.ref), inPlace: false)
        view.needsLayout = true
    }
}

// MARK: - Cells

final class NameCellView: NSTableCellView {
    private var isHiddenItem = false
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColor() } }
    private func updateColor() {
        guard isHiddenItem else { return }
        textField?.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : NSColor.hiddenItemText(for: self)
    }
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let tags = NSStackView()
    private var item: FileItem?
    private lazy var iconWidth = icon.widthAnchor.constraint(equalToConstant: 16)
    private lazy var iconHeight = icon.heightAnchor.constraint(equalToConstant: 16)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.focusRingType = .none
        tags.translatesAutoresizingMaskIntoConstraints = false
        tags.spacing = -4
        addSubview(icon)
        addSubview(label)
        addSubview(tags)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            iconHeight,
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            tags.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            tags.centerYAnchor.constraint(equalTo: centerYAnchor),
            tags.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Finder's drag image: the icon, and the name in white on an accent-coloured rounded pill.
    override var draggingImageComponents: [NSDraggingImageComponent] {
        var components: [NSDraggingImageComponent] = []
        if let image = icon.image {
            let component = NSDraggingImageComponent(key: .icon)
            component.contents = image
            component.frame = icon.frame
            components.append(component)
        }
        let font = label.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let text = NSAttributedString(string: label.stringValue, attributes: [
            .font: font, .foregroundColor: NSColor.white, .paragraphStyle: style,
        ])
        // The label's cell insets its text by 2pt on each side.
        let textSize = text.size()
        let textWidth = ceil(min(textSize.width, label.frame.width - 4))
        guard textWidth > 0 else { return components }
        let padding = NSSize(width: 4, height: 1)
        let pill = NSRect(x: label.frame.minX + 2 - padding.width,
                          y: (label.frame.midY - ceil(textSize.height) / 2 - padding.height).rounded(),
                          width: textWidth + padding.width * 2,
                          height: ceil(textSize.height) + padding.height * 2)
        var tint = NSColor.controlAccentColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint = NSColor.selectedContentBackgroundColor.usingColorSpace(.sRGB) ?? tint
        }
        let image = NSImage(size: pill.size, flipped: false) { rect in
            tint.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            text.draw(with: NSRect(x: padding.width, y: padding.height, width: textWidth, height: ceil(textSize.height)),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
        let component = NSDraggingImageComponent(key: .label)
        component.contents = image
        component.frame = pill
        components.append(component)
        return components
    }

    func configure(_ item: FileItem, iconSize: CGFloat, font: NSFont, preview: Bool) {
        self.item = item
        iconWidth.constant = iconSize
        iconHeight.constant = iconSize
        icon.image = item.icon
        icon.alphaValue = item.isHidden ? 0.5 : 1
        if preview {
            let ref = item.ref
            Thumbnails.shared.thumbnail(for: item, size: iconSize) { [weak self] image in
                guard self?.item?.ref == ref else { return }
                self?.icon.image = image
            }
        }
        label.font = font
        label.stringValue = item.displayName
        isHiddenItem = item.isHidden
        label.textColor = item.isHidden ? NSColor.hiddenItemText(for: self) : .labelColor
        tags.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tag in item.tags.prefix(3) {
            guard let color = FinderTag.color(for: tag) else { continue }
            let dot = TagDotView()
            dot.color = color
            dot.bordered = true
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
            tags.addArrangedSubview(dot)
        }
    }
}

final class TextCellView: NSTableCellView {
    private var dimmed = false
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColor() } }
    private func updateColor() {
        guard dimmed else { return }
        label.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : NSColor.hiddenItemText(for: self)
    }
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String, alignment: NSTextAlignment, dimmed: Bool, font: NSFont) {
        label.font = font
        label.stringValue = text
        label.alignment = alignment
        self.dimmed = dimmed
        label.textColor = dimmed ? NSColor.hiddenItemText(for: self) : .secondaryLabelColor
    }
}

// MARK: - Row diff

/// The row changes that turn one list of items into another: removals first, then moves and insertions
/// in order of the new positions. Items are compared by identity (`reconcile` keeps the objects that stay).
enum RowDiff {
    enum Step: Equatable {
        case remove(IndexSet)
        case move(from: Int, to: Int)
        case insert(Int)
    }

    static func steps(from old: [FileItem], to new: [FileItem]) -> [Step] {
        var steps: [Step] = []
        let kept = Set(new.map(ObjectIdentifier.init))
        let removed = IndexSet(old.indices.filter { !kept.contains(ObjectIdentifier(old[$0])) })
        var working = old
        if !removed.isEmpty {
            steps.append(.remove(removed))
            for i in removed.reversed() { working.remove(at: i) }
        }
        for (i, item) in new.enumerated() {
            if i < working.count, working[i] === item { continue }
            if let j = working[i...].firstIndex(where: { $0 === item }) {
                steps.append(.move(from: j, to: i))
                working.insert(working.remove(at: j), at: i)
            } else {
                steps.append(.insert(i))
                working.insert(item, at: i)
            }
        }
        return steps
    }
}
