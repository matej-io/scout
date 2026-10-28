import AppKit

final class FileOutlineView: NSOutlineView {
    weak var pane: PaneViewController?
    var onDragExit: (() -> Void)?

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragExit?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        onDragExit?()
    }

    override func keyDown(with event: NSEvent) {
        if BrowserKeys.handle(event, pane: pane) { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
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

    private struct Column {
        let id: String
        let title: String
        let width: CGFloat
        let sortKey: SortKey
        let alignment: NSTextAlignment
    }

    private static let columns: [Column] = [
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

    private static var visibleColumns: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "listColumns") ?? ["name", "modified", "size", "kind"]) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "listColumns") }
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
        outline.rowHeight = 20
        outline.intercellSpacing = NSSize(width: 3, height: 0)
        outline.indentationPerLevel = 16
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
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
        let scrollOrigin = scroll.contentView.bounds.origin
        let sameFolder = newItems.first?.ref.parent == items.first?.ref.parent && !items.isEmpty
        items = newItems
        suppressSelectionNotifications = true
        outline.reloadData()
        syncSortIndicator()
        // Re-open folders that were expanded before the refresh.
        let wanted = expandedRefs
        expandedRefs = []
        for item in items where wanted.contains(item.ref) { expand(item, restoring: wanted) }
        if let refs { selectRefs(refs, scroll: !sameFolder) }
        if sameFolder { scroll.contentView.scroll(to: scrollOrigin) }
        suppressSelectionNotifications = false
        pane?.selectionDidChange()
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
            guard let self, case .success(let children) = result else { return }
            item.children = self.pane?.sorted(children) ?? children
            self.outline.reloadItem(item, reloadChildren: true)
        }
    }

    private func findItem(_ ref: ItemRef) -> FileItem? {
        for row in 0..<outline.numberOfRows {
            if let item = outline.item(atRow: row) as? FileItem, item.ref == ref { return item }
        }
        return nil
    }

    // MARK: Expansion (children load asynchronously, also over SSH)

    private func expand(_ item: FileItem, restoring: Set<ItemRef> = []) {
        if item.children != nil {
            outline.expandItem(item)
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
            cell.configure(item)
            cell.textField?.delegate = self
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? TextCellView ?? TextCellView(identifier: column.identifier)
        let text: String
        switch id {
        case "modified": text = Fmt.dateString(item.modified)
        case "created": text = Fmt.dateString(item.created)
        case "lastOpened": text = Fmt.dateString(item.lastOpened)
        case "added": text = Fmt.dateString(item.added)
        case "size": text = item.isBrowsable ? "--" : Fmt.size(item.size)
        case "kind": text = item.kind
        case "tags": text = item.tags.joined(separator: ", ")
        default: text = ""
        }
        cell.configure(text, alignment: id == "size" ? .right : .left, dimmed: item.isHidden)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
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
        if let item { pane?.rename(item, to: field.stringValue) }
        field.stringValue = item?.displayName ?? field.stringValue
        view.window?.makeFirstResponder(outline)
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
        column.isHidden = !visible.contains(id)
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
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            tags.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            tags.centerYAnchor.constraint(equalTo: centerYAnchor),
            tags.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: FileItem) {
        icon.image = item.icon
        icon.alphaValue = item.isHidden ? 0.5 : 1
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

    func configure(_ text: String, alignment: NSTextAlignment, dimmed: Bool) {
        label.stringValue = text
        label.alignment = alignment
        self.dimmed = dimmed
        label.textColor = dimmed ? NSColor.hiddenItemText(for: self) : .secondaryLabelColor
    }
}
