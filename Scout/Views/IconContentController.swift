import AppKit
import UniformTypeIdentifiers

/// Finder’s icon view.
final class IconContentController: NSViewController, BrowserContent, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate {
    weak var pane: PaneViewController? { didSet { collection.pane = pane } }
    private let collection = FileCollectionView()
    private let layout = IconGridLayout()
    private let scroll = NSScrollView()
    private var items: [FileItem] = []
    private var editing: (item: FileItem, field: NSTextField)?
    private lazy var springLoader = SpringLoader(blink: { [weak self] key, on in
        guard let self, let ref = key.base as? ItemRef, let index = self.items.firstIndex(where: { $0.ref == ref }) else { return }
        (self.collection.item(at: IndexPath(item: index, section: 0)) as? IconItem)?.highlightState = on ? .asDropTarget : .none
    }, open: { [weak self] key in
        guard let ref = key.base as? ItemRef else { return }
        self?.pane?.springOpen(.folder(ref))
    })

    override func loadView() {
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 8, left: 10, bottom: 12, right: 10)
        updateItemSize()
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.controlBackgroundColor]
        collection.register(IconItem.self, forItemWithIdentifier: IconItem.id)
        collection.registerForDraggedTypes(DragSupport.types)
        collection.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        collection.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        collection.onDoubleClick = { [weak self] in self?.pane?.open(self?.selectedItems ?? []) }
        collection.onFocusChange = { [weak self] in self?.refreshVisible() }
        collection.typeSelect = { [weak self] prefix in self?.typeSelect(prefix) }
        collection.onDragExit = { [weak self] in self?.springLoader.cancel() }

        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        view = scroll
    }

    var focusView: NSView { collection }

    private func updateItemSize() {
        let metrics = IconMetrics.current
        layout.itemSize = metrics.itemSize
        layout.minimumLineSpacing = metrics.lineSpacing
    }

    func iconSizeChanged() {
        updateItemSize()
        layout.invalidateLayout()
        let selection = collection.selectionIndexPaths
        collection.reloadData()
        collection.selectionIndexPaths = selection
    }

    func viewOptionsChanged() { iconSizeChanged() }

    // MARK: BrowserContent

    func display(_ newItems: [FileItem], select refs: [ItemRef]?) {
        items = newItems
        collection.reloadData()
        if let refs { select(refs) }
        pane?.selectionDidChange()
    }

    var selectedItems: [FileItem] {
        collection.selectionIndexPaths.sorted().compactMap { $0.item < items.count ? items[$0.item] : nil }
    }

    func select(_ refs: [ItemRef]) {
        let wanted = Set(refs)
        let paths = Set(items.enumerated().filter { wanted.contains($0.element.ref) }.map { IndexPath(item: $0.offset, section: 0) })
        collection.selectionIndexPaths = paths
        if let first = paths.min() { collection.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge) }
        refreshVisible()
    }

    private func refreshVisible() {
        for case let item as IconItem in collection.visibleItems() { item.updateAppearance() }
    }

    private func typeSelect(_ prefix: String) {
        guard let index = items.firstIndex(where: { $0.displayName.lowercased().hasPrefix(prefix.lowercased()) }) else { return }
        select([items[index].ref])
        pane?.selectionDidChange()
    }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: IconItem.id, for: indexPath) as! IconItem
        cell.configure(items[indexPath.item], metrics: IconMetrics.current, collection: collection)
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        pane?.selectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        pane?.selectionDidChange()
    }

    // MARK: Drag and drop

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        DragSupport.writer(for: items[indexPath.item])
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let index = proposedDropIndexPath.pointee.item
        if proposedDropOperation.pointee == .on, index < items.count, items[index].isBrowsable {
            springLoader.hover(items[index].ref)
            return DragSupport.operation(for: draggingInfo, destination: items[index].ref)
        }
        springLoader.hover(nil)
        guard let destination = pane?.location.ref else { return [] }
        proposedDropOperation.pointee = .before
        return DragSupport.operation(for: draggingInfo, destination: destination)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        springLoader.cancel()
        var destination = pane?.location.ref
        if dropOperation == .on, indexPath.item < items.count, items[indexPath.item].isBrowsable {
            destination = items[indexPath.item].ref
        }
        guard let destination else { return false }
        return DragSupport.accept(draggingInfo, destination: destination, window: view.window)
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        if operation == .delete { pane?.moveToTrash(nil) }
    }

    // MARK: Rename

    func beginRename(_ ref: ItemRef) {
        guard let index = items.firstIndex(where: { $0.ref == ref }) else { return }
        let path = IndexPath(item: index, section: 0)
        collection.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        guard let cell = collection.item(at: path) as? IconItem else { return }
        let item = items[index]
        let field = cell.beginEditing()
        field.delegate = self
        editing = (item, field)
        view.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let ext = (item.name as NSString).pathExtension
            let length = (item.name as NSString).length
            editor.selectedRange = NSRange(location: 0, length: ext.isEmpty || item.isDirectory ? length : length - ext.count - 1)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let editing {
            editing.field.stringValue = editing.item.name
            self.editing = nil
            finishEditing(editing.field)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            view.window?.makeFirstResponder(collection)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let current = editing
        editing = nil
        finishEditing(field)
        if let current { pane?.rename(current.item, to: field.stringValue) }
    }

    private func finishEditing(_ field: NSTextField) {
        for case let item as IconItem in collection.visibleItems() where item.label === field { item.endEditing() }
        view.window?.makeFirstResponder(collection)
    }
}

// MARK: - Layout

final class IconGridLayout: NSCollectionViewFlowLayout {
    override func layoutAttributesForInterItemGap(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? { nil }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        // Left-align the grid like Finder instead of spreading items across the row.
        let attributes = super.layoutAttributesForElements(in: rect).compactMap { $0.copy() as? NSCollectionViewLayoutAttributes }
        guard let width = collectionView?.bounds.width else { return attributes }
        let usable = width - sectionInset.left - sectionInset.right
        let perRow = max(1, Int(usable / itemSize.width))
        let spacing = perRow > 1 ? (usable - CGFloat(perRow) * itemSize.width) / CGFloat(perRow) : 0
        for attr in attributes where attr.representedElementCategory == .item {
            guard let index = attr.indexPath?.item else { continue }
            let col = index % perRow
            attr.frame.origin.x = sectionInset.left + spacing / 2 + CGFloat(col) * (itemSize.width + spacing)
        }
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let attr = super.layoutAttributesForItem(at: indexPath)?.copy() as? NSCollectionViewLayoutAttributes,
              let width = collectionView?.bounds.width else { return nil }
        let usable = width - sectionInset.left - sectionInset.right
        let perRow = max(1, Int(usable / itemSize.width))
        let spacing = perRow > 1 ? (usable - CGFloat(perRow) * itemSize.width) / CGFloat(perRow) : 0
        attr.frame.origin.x = sectionInset.left + spacing / 2 + CGFloat(indexPath.item % perRow) * (itemSize.width + spacing)
        return attr
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }
}

// MARK: - Collection view

final class FileCollectionView: NSCollectionView {
    weak var pane: PaneViewController?
    var onDoubleClick: (() -> Void)?
    var onFocusChange: (() -> Void)?
    var typeSelect: ((String) -> Void)?
    var onDragExit: (() -> Void)?

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragExit?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // draggingEnded(_:) is optional and not every AppKit view implements it; an unguarded super call throws.
        if NSCollectionView.instancesRespond(to: #selector(draggingEnded(_:))) { super.draggingEnded(sender) }
        onDragExit?()
    }
    private var typeBuffer = ""
    private var lastType = Date.distantPast

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, !selectionIndexPaths.isEmpty,
           indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil {
            onDoubleClick?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if BrowserKeys.handle(event, pane: pane) { return }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags.isEmpty, let chars = event.characters, let scalar = chars.unicodeScalars.first,
           CharacterSet.alphanumerics.union(.punctuationCharacters).contains(scalar) {
            if Date().timeIntervalSince(lastType) > 1 { typeBuffer = "" }
            typeBuffer += chars
            lastType = Date()
            typeSelect?(typeBuffer)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(path) {
                selectionIndexPaths = [path]
                delegate?.collectionView?(self, didSelectItemsAt: [path])
            }
        } else {
            selectionIndexPaths = []
            delegate?.collectionView?(self, didDeselectItemsAt: [])
        }
        onFocusChange?()
        return pane?.contextMenu(for: pane?.selectedItems ?? [])
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        DispatchQueue.main.async { self.onFocusChange?() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        DispatchQueue.main.async { self.onFocusChange?() }
        return ok
    }

    var isFocused: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move, .generic] : [.copy, .move, .link, .generic, .delete]
    }
}

// MARK: - Item

final class IconItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("IconItem")

    private let iconBackground = NSView()
    private let icon = NSImageView()
    let label = NSTextField(wrappingLabelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    private let tagDots = NSStackView()
    private var item: FileItem?
    private var metrics = IconMetrics.current
    private weak var collection: FileCollectionView?
    private var isEditingName = false

    override func loadView() {
        let root = FlippedView()
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 6
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.drawsBackground = false
        label.focusRingType = .none
        infoLabel.textColor = .controlAccentColor
        infoLabel.lineBreakMode = .byTruncatingTail
        tagDots.spacing = -3
        root.addSubview(iconBackground)
        root.addSubview(icon)
        root.addSubview(label)
        root.addSubview(infoLabel)
        root.addSubview(tagDots)
        view = root
        imageView = icon
        textField = label
    }

    override var isSelected: Bool { didSet { updateAppearance() } }
    override func viewDidAppear() { super.viewDidAppear(); updateAppearance() }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateAppearance() } }

    func configure(_ item: FileItem, metrics: IconMetrics, collection: FileCollectionView) {
        self.item = item
        self.metrics = metrics
        self.collection = collection
        icon.image = item.icon
        icon.alphaValue = item.isHidden ? 0.5 : 1
        label.stringValue = item.displayName
        label.font = metrics.font
        label.alignment = metrics.labelsRight ? .left : .center
        infoLabel.font = metrics.infoFont
        infoLabel.alignment = label.alignment
        infoLabel.stringValue = ""
        infoLabel.isHidden = !metrics.showInfo
        tagDots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tag in item.tags.prefix(3) {
            guard let color = FinderTag.color(for: tag) else { continue }
            let dot = TagDotView()
            dot.color = color
            dot.bordered = true
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 9).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 9).isActive = true
            tagDots.addArrangedSubview(dot)
        }
        let ref = item.ref
        if metrics.showPreview {
            Thumbnails.shared.thumbnail(for: item, size: metrics.iconSize) { [weak self] image in
                guard self?.item?.ref == ref else { return }
                self?.icon.image = image
            }
        }
        if metrics.showInfo {
            ItemInfo.text(for: item) { [weak self] text in
                guard let self, self.item?.ref == ref else { return }
                self.infoLabel.stringValue = text ?? ""
                self.view.needsLayout = true
            }
        }
        updateAppearance()
        view.needsLayout = true
    }

    func updateAppearance() {
        guard !isEditingName else { return }
        let selected = isSelected || highlightState == .forSelection
        let dropTarget = highlightState == .asDropTarget
        let focused = collection?.isFocused ?? false
        iconBackground.layer?.backgroundColor = (selected || dropTarget)
            ? NSColor.unemphasizedSelectedContentBackgroundColor.cgColor : nil
        if selected {
            label.layer?.backgroundColor = (focused ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).cgColor
            label.textColor = focused ? .alternateSelectedControlTextColor : .labelColor
        } else {
            label.layer?.backgroundColor = nil
            label.textColor = item?.isHidden == true ? NSColor.hiddenItemText(for: view) : .labelColor
        }
        view.needsLayout = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        let s = metrics.iconSize
        let lineHeight = metrics.lineHeight
        let maxHeight = isEditingName ? lineHeight * 4 : lineHeight * 2 + 2
        let hasInfo = metrics.showInfo && !infoLabel.stringValue.isEmpty && !isEditingName
        let infoHeight = hasInfo ? metrics.infoLineHeight : 0
        infoLabel.isHidden = !hasInfo
        if metrics.labelsRight {
            // Icon on the left, name (and info) beside it, vertically centred like Finder.
            let iconRect = NSRect(x: 6, y: (bounds.height - s) / 2, width: s, height: s)
            icon.frame = iconRect
            iconBackground.frame = iconRect.insetBy(dx: -4, dy: -4)
            let x = iconRect.maxX + 8
            let maxWidth = bounds.width - x - 4
            var size = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxWidth - 8, height: maxHeight))
            size.width = min(maxWidth, ceil(size.width) + 8)
            size.height = min(maxHeight, ceil(size.height) + 1)
            let top = (bounds.height - size.height - infoHeight) / 2
            label.frame = NSRect(x: x, y: top, width: size.width, height: size.height)
            infoLabel.frame = NSRect(x: x, y: label.frame.maxY, width: maxWidth, height: infoHeight)
        } else {
            let iconRect = NSRect(x: (bounds.width - s) / 2, y: 6, width: s, height: s)
            icon.frame = iconRect
            iconBackground.frame = iconRect.insetBy(dx: -4, dy: -4)
            let maxWidth = bounds.width - 6
            var size = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxWidth - 8, height: maxHeight))
            size.width = min(maxWidth, ceil(size.width) + 8)
            size.height = min(maxHeight, ceil(size.height) + 1)
            label.frame = NSRect(x: (bounds.width - size.width) / 2, y: iconRect.maxY + 7, width: size.width, height: size.height)
            infoLabel.frame = NSRect(x: 3, y: label.frame.maxY, width: bounds.width - 6, height: infoHeight)
        }
        let dotsSize = tagDots.fittingSize
        tagDots.frame = NSRect(x: label.frame.maxX - 2, y: label.frame.minY + 3, width: dotsSize.width, height: dotsSize.height)
    }

    func beginEditing() -> NSTextField {
        isEditingName = true
        label.stringValue = item?.name ?? label.stringValue
        label.isEditable = true
        label.isSelectable = true
        label.maximumNumberOfLines = 4
        label.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        label.textColor = .labelColor
        label.layer?.borderWidth = 1
        label.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        view.needsLayout = true
        return label
    }

    func endEditing() {
        isEditingName = false
        label.isEditable = false
        label.isSelectable = false
        label.maximumNumberOfLines = 2
        label.layer?.borderWidth = 0
        label.stringValue = item?.displayName ?? label.stringValue
        updateAppearance()
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - View options

/// Icon view sizes derived from the View Options settings.
struct IconMetrics {
    let iconSize: CGFloat
    let font: NSFont
    let infoFont: NSFont
    let labelsRight: Bool
    let showInfo: Bool
    let showPreview: Bool
    let lineHeight: CGFloat
    let infoLineHeight: CGFloat
    let itemSize: NSSize
    let lineSpacing: CGFloat

    static var current: IconMetrics {
        let prefs = Prefs.shared
        let s = prefs.iconSize
        let spacing = prefs.iconGridSpacing
        let font = NSFont.systemFont(ofSize: prefs.iconTextSize)
        let infoFont = NSFont.systemFont(ofSize: max(9, prefs.iconTextSize - 1))
        func height(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) + 1 }
        let lineHeight = height(font)
        let infoLineHeight = prefs.iconShowInfo ? height(infoFont) : 0
        let itemSize: NSSize
        if prefs.iconLabelsRight {
            let text = lineHeight * 2 + 2 + infoLineHeight
            itemSize = NSSize(width: s + 18 + 100 + spacing * 2, height: max(s + 8, text) + 8)
        } else {
            itemSize = NSSize(width: max(s, 52) + spacing * 2, height: s + 6 + 7 + lineHeight * 2 + 2 + infoLineHeight + 5)
        }
        return IconMetrics(iconSize: s, font: font, infoFont: infoFont, labelsRight: prefs.iconLabelsRight,
                           showInfo: prefs.iconShowInfo, showPreview: prefs.iconShowPreview, lineHeight: lineHeight,
                           infoLineHeight: infoLineHeight, itemSize: itemSize, lineSpacing: max(0, (spacing - 24) / 2))
    }
}

/// Finder's “Show item info”: how many items a folder holds, an image's pixel size, or a file's size.
enum ItemInfo {
    private static let cache = NSCache<NSString, NSString>()
    private static let queue = DispatchQueue(label: "io.matej.scout.iteminfo", qos: .utility, attributes: .concurrent)

    static func text(for item: FileItem, completion: @escaping (String?) -> Void) {
        guard case .local(let url) = item.ref, url.isFileURL else {
            completion(item.isBrowsable ? nil : Fmt.size(item.size))
            return
        }
        let showHidden = Prefs.shared.showHidden
        let key = "\(url.path)#\(item.modified?.timeIntervalSince1970 ?? 0)#\(showHidden)" as NSString
        if let cached = cache.object(forKey: key) { completion(cached.length == 0 ? nil : cached as String); return }
        let isBrowsable = item.isBrowsable
        let size = item.size
        queue.async {
            let text = compute(url, isBrowsable: isBrowsable, size: size, showHidden: showHidden)
            cache.setObject((text ?? "") as NSString, forKey: key)
            DispatchQueue.main.async { completion(text) }
        }
    }

    private static func compute(_ url: URL, isBrowsable: Bool, size: Int64?, showHidden: Bool) -> String? {
        if isBrowsable {
            let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
            guard let count = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: options).count else { return nil }
            return count == 1 ? "1 item" : "\(count) items"
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int {
            return "\(width) × \(height)"
        }
        return size.map { Fmt.size($0) }
    }
}
