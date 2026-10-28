import AppKit

final class FileBrowser: NSBrowser {
    weak var pane: PaneViewController?
    var onDragExit: (() -> Void)?

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragExit?()
    }
    var onMenu: ((Int, Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if BrowserKeys.handle(event, pane: pane) { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        var row = -1
        var column = -1
        let point = convert(event.locationInWindow, from: nil)
        _ = getRow(&row, column: &column, for: point)
        return onMenu?(row, column)
    }
}

/// Finder’s column view, including the preview column for files.
final class ColumnContentController: NSViewController, BrowserContent, NSBrowserDelegate {
    weak var pane: PaneViewController? { didSet { browser.pane = pane } }
    private let browser = FileBrowser()
    private let root = FileItem(ref: .local(URL(fileURLWithPath: "/")), name: "", isDirectory: true, isHidden: false,
                                size: nil, modified: nil, kind: "")
    private var loading = Set<ObjectIdentifier>()

    private struct Cell: Hashable { let row: Int; let column: Int }
    /// In column view a spring-loaded folder is selected, which opens its contents in the next column.
    private lazy var springLoader = SpringLoader(blink: { _, _ in }, open: { [weak self] key in
        guard let self, let cell = key.base as? Cell else { return }
        self.browser.selectRowIndexes([cell.row], inColumn: cell.column)
        self.pane?.selectionDidChange()
    })

    override func loadView() {
        browser.delegate = self
        browser.isTitled = false
        browser.hasHorizontalScroller = true
        browser.autohidesScroller = true
        browser.separatesColumns = true
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.allowsTypeSelect = true
        browser.reusesColumns = true
        browser.columnResizingType = .userColumnResizing
        browser.minColumnWidth = 120
        browser.setDefaultColumnWidth(240)
        browser.rowHeight = 22
        browser.backgroundColor = .controlBackgroundColor
        browser.setCellClass(FileBrowserCell.self)
        browser.target = self
        browser.action = #selector(selectionChanged(_:))
        browser.doubleAction = #selector(doubleClicked(_:))
        browser.pathSeparator = "\u{1}"
        browser.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        browser.registerForDraggedTypes(DragSupport.types)
        browser.onMenu = { [weak self] row, column in self?.menu(row: row, column: column) }
        browser.onDragExit = { [weak self] in self?.springLoader.cancel() }
        view = browser
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Leave room under the toolbar, like the other views do via automatic insets.
        let top = view.safeAreaInsets.top
        if browser.frame.origin.y != 0 || top > 0 {
            for subview in browser.subviews where subview is NSScrollView {
                (subview as? NSScrollView)?.automaticallyAdjustsContentInsets = true
            }
        }
    }

    var focusView: NSView { browser }

    // MARK: BrowserContent

    func display(_ newItems: [FileItem], select refs: [ItemRef]?) {
        // Keep loaded children along the open path so the columns survive a refresh.
        let oldChildren = Dictionary((root.children ?? []).map { ($0.ref, $0.children) }, uniquingKeysWith: { a, _ in a })
        for item in newItems where item.children == nil { item.children = oldChildren[item.ref] ?? nil }
        let previousPath = browser.path()
        root.children = newItems
        browser.loadColumnZero()
        if let refs, !refs.isEmpty {
            select(refs)
        } else if !previousPath.isEmpty, previousPath != browser.pathSeparator {
            browser.setPath(previousPath)
        }
        pane?.selectionDidChange()
    }

    var selectedItems: [FileItem] {
        let column = browser.selectedColumn
        guard column >= 0, let rows = browser.selectedRowIndexes(inColumn: column) else { return [] }
        return rows.compactMap { browser.item(atRow: $0, inColumn: column) as? FileItem }
    }

    var targetFolder: ItemRef? {
        let selection = selectedItems
        if selection.count == 1, selection[0].isBrowsable { return selection[0].ref }
        let column = browser.selectedColumn
        if column > 0, let parent = browser.parentForItems(inColumn: column) as? FileItem { return parent.ref }
        return nil
    }

    func select(_ refs: [ItemRef]) {
        guard let parentRef = refs.first?.parent else { return }
        for column in 0...max(0, browser.lastColumn) {
            let parent = browser.parentForItems(inColumn: column) as? FileItem
            let matches = column == 0 ? (parent === root) : (parent?.ref == parentRef)
            let isRootColumn = column == 0 && (root.children ?? []).contains { refs.contains($0.ref) }
            guard matches && (column > 0 || isRootColumn) else { continue }
            let children = parent?.children ?? []
            var rows = IndexSet()
            for (i, child) in children.enumerated() where refs.contains(child.ref) { rows.insert(i) }
            browser.selectRowIndexes(rows, inColumn: column)
            if let first = rows.first { browser.scrollRowToVisible(first, inColumn: column) }
            return
        }
    }

    func beginRename(_ ref: ItemRef) {
        if let item = selectedItems.first(where: { $0.ref == ref }) { pane?.promptRename(item) }
        else if let item = (root.children ?? []).first(where: { $0.ref == ref }) { pane?.promptRename(item) }
    }

    func childrenChanged(in folder: ItemRef) {
        for column in 0...max(0, browser.lastColumn) {
            guard let parent = browser.parentForItems(inColumn: column) as? FileItem, parent !== root, parent.ref == folder else { continue }
            let selected = browser.selectedRowIndexes(inColumn: column).map { rows in rows.compactMap { parent.children?[safe: $0]?.ref } } ?? []
            FileService.list(folder, showHidden: Prefs.shared.showHidden) { [weak self] result in
                guard let self, case .success(let list) = result else { return }
                parent.children = self.pane?.sorted(list) ?? list
                self.browser.reloadColumn(column)
                var rows = IndexSet()
                for (i, child) in (parent.children ?? []).enumerated() where selected.contains(child.ref) { rows.insert(i) }
                if !rows.isEmpty { self.browser.selectRowIndexes(rows, inColumn: column) }
            }
        }
    }

    // MARK: NSBrowserDelegate (item based)

    func rootItem(for browser: NSBrowser) -> Any? { root }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? FileItem else { return 0 }
        if let children = item.children { return children.count }
        if item.isBrowsable { load(item) }
        return 0
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        (item as! FileItem).children![index]
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        guard let item = item as? FileItem else { return true }
        return item !== root && !item.isBrowsable
    }

    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        (item as? FileItem)?.displayName
    }

    func browser(_ sender: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? FileBrowserCell, let item = sender.item(atRow: row, inColumn: column) as? FileItem else { return }
        cell.fileItem = item
    }

    func browser(_ browser: NSBrowser, previewViewControllerForLeafItem item: Any) -> NSViewController? {
        let controller = PreviewColumnController()
        return controller
    }

    func browser(_ browser: NSBrowser, shouldEditItem item: Any?) -> Bool { false }

    private func load(_ item: FileItem) {
        let key = ObjectIdentifier(item)
        guard !loading.contains(key) else { return }
        loading.insert(key)
        FileService.list(item.ref, showHidden: Prefs.shared.showHidden) { [weak self] result in
            guard let self else { return }
            self.loading.remove(key)
            switch result {
            case .success(let list): item.children = self.pane?.sorted(list) ?? list
            case .failure: item.children = []
            }
            for column in 0...max(0, self.browser.lastColumn) where (self.browser.parentForItems(inColumn: column) as? FileItem) === item {
                self.browser.reloadColumn(column)
            }
        }
    }

    // MARK: Actions

    @objc private func selectionChanged(_ sender: Any?) {
        pane?.selectionDidChange()
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let files = selectedItems.filter { !$0.isBrowsable }
        if !files.isEmpty { pane?.open(files) }
    }

    private func menu(row: Int, column: Int) -> NSMenu? {
        if row >= 0, column >= 0 {
            let selected = browser.selectedRowIndexes(inColumn: column) ?? []
            if !selected.contains(row) || browser.selectedColumn != column {
                browser.selectRowIndexes([row], inColumn: column)
                pane?.selectionDidChange()
            }
        }
        return pane?.contextMenu(for: row >= 0 ? selectedItems : [])
    }

    // MARK: Drag and drop

    func browser(_ browser: NSBrowser, canDragRowsWith rowIndexes: IndexSet, inColumn column: Int, with event: NSEvent) -> Bool { true }

    func browser(_ browser: NSBrowser, writeRowsWith rowIndexes: IndexSet, inColumn column: Int, to pasteboard: NSPasteboard) -> Bool {
        let items = rowIndexes.compactMap { browser.item(atRow: $0, inColumn: column) as? FileItem }
        guard !items.isEmpty else { return false }
        pasteboard.clearContents()
        let urls = items.compactMap { $0.ref.localURL }.filter(\.isFileURL)
        pasteboard.declareTypes([.scoutRefs] + (urls.isEmpty ? [] : [.fileURL]), owner: nil)
        pasteboard.setData(try? JSONEncoder().encode(items.map(\.ref)), forType: .scoutRefs)
        if !urls.isEmpty { pasteboard.writeObjects(urls as [NSURL]) }
        return true
    }

    func browser(_ browser: NSBrowser, validateDrop info: NSDraggingInfo, proposedRow row: UnsafeMutablePointer<Int>,
                 column: UnsafeMutablePointer<Int>, dropOperation: UnsafeMutablePointer<NSBrowser.DropOperation>) -> NSDragOperation {
        if dropOperation.pointee == .on, let item = browser.item(atRow: row.pointee, inColumn: column.pointee) as? FileItem, item.isBrowsable {
            springLoader.hover(Cell(row: row.pointee, column: column.pointee))
            return DragSupport.operation(for: info, destination: item.ref)
        }
        springLoader.hover(nil)
        dropOperation.pointee = .above
        guard let destination = folder(forColumn: column.pointee) else { return [] }
        return DragSupport.operation(for: info, destination: destination)
    }

    func browser(_ browser: NSBrowser, acceptDrop info: NSDraggingInfo, atRow row: Int, column: Int, dropOperation: NSBrowser.DropOperation) -> Bool {
        springLoader.cancel()
        var destination = folder(forColumn: column)
        if dropOperation == .on, let item = browser.item(atRow: row, inColumn: column) as? FileItem, item.isBrowsable {
            destination = item.ref
        }
        guard let destination else { return false }
        return DragSupport.accept(info, destination: destination, window: view.window)
    }

    private func folder(forColumn column: Int) -> ItemRef? {
        guard let parent = browser.parentForItems(inColumn: column) as? FileItem else { return pane?.location.ref }
        return parent === root ? pane?.location.ref : parent.ref
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Cell

final class FileBrowserCell: NSBrowserCell {
    var fileItem: FileItem? {
        didSet {
            guard let fileItem else { return }
            let icon = fileItem.icon.copy() as! NSImage
            icon.size = NSSize(width: 16, height: 16)
            image = icon
            isLeaf = !fileItem.isBrowsable
            font = .systemFont(ofSize: 13)
        }
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let item = fileItem else { super.drawInterior(withFrame: cellFrame, in: controlView); return }
        let highlighted = isHighlighted
        let emphasized = backgroundStyle == .emphasized
        var x = cellFrame.minX + 8
        if let image {
            let r = NSRect(x: x, y: cellFrame.midY - 8, width: 16, height: 16)
            image.draw(in: r, from: .zero, operation: .sourceOver, fraction: item.isHidden ? 0.5 : 1, respectFlipped: true, hints: nil)
            x += 22
        }
        var color: NSColor = item.isHidden ? .tertiaryLabelColor : .labelColor
        if highlighted && emphasized { color = .alternateSelectedControlTextColor }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color, .paragraphStyle: style]
        let text = item.displayName as NSString
        let chevronWidth: CGFloat = item.isBrowsable ? 22 : 0
        let textRect = NSRect(x: x, y: cellFrame.midY - 8.5, width: cellFrame.maxX - x - chevronWidth - 6, height: 17)
        text.draw(in: textRect, withAttributes: attrs)
    }
}

// MARK: - Preview column

final class PreviewColumnController: NSViewController {
    private let imageView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let infoStack = NSStackView()

    override var representedObject: Any? {
        didSet { update() }
    }

    override func loadView() {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.alignment = .left
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 6
        let stack = NSStackView(views: [imageView, nameLabel, detailLabel, infoStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(18, after: imageView)
        stack.setCustomSpacing(16, after: detailLabel)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.heightAnchor.constraint(equalToConstant: 180),
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        view = container
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
    }

    private func update() {
        guard let item = representedObject as? FileItem else { return }
        _ = view
        imageView.image = item.icon
        Thumbnails.shared.thumbnail(for: item, size: 256) { [weak self] image in
            guard (self?.representedObject as? FileItem)?.ref == item.ref else { return }
            self?.imageView.image = image
        }
        nameLabel.stringValue = item.displayName
        detailLabel.stringValue = item.size.map { "\(item.kind) – \(Fmt.size($0))" } ?? item.kind
        infoStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = NSTextField(labelWithString: "Information")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        infoStack.addArrangedSubview(header)
        for (title, date) in [("Created", item.created), ("Modified", item.modified), ("Last opened", item.lastOpened)] {
            guard let date else { continue }
            infoStack.addArrangedSubview(InfoRow(title: title, value: Fmt.longDate.string(from: date)))
        }
    }
}

final class InfoRow: NSStackView {
    init(title: String, value: String) {
        super.init(frame: .zero)
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        let v = NSTextField(labelWithString: value)
        v.font = .systemFont(ofSize: 11, weight: .medium)
        v.alignment = .right
        v.lineBreakMode = .byTruncatingTail
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(t)
        addArrangedSubview(v)
        distribution = .fill
        spacing = 12
    }

    required init?(coder: NSCoder) { fatalError() }
}
