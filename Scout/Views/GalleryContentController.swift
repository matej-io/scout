import AppKit

/// Finder’s gallery view: a large preview, a thumbnail strip and an inspector.
final class GalleryContentController: NSViewController, BrowserContent, NSCollectionViewDataSource, NSCollectionViewDelegate {
    weak var pane: PaneViewController? { didSet { strip.pane = pane } }
    private let preview = NSImageView()
    private let strip = FileCollectionView()
    private let stripScroll = NSScrollView()
    private let inspector = GalleryInspector()
    private var items: [FileItem] = []
    private lazy var springLoader = SpringLoader(blink: { _, _ in }, open: { [weak self] key in
        guard let ref = key.base as? ItemRef else { return }
        self?.pane?.springOpen(.folder(ref))
    })

    override func loadView() {
        let root = NSView()
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 60, height: 60)
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        strip.collectionViewLayout = layout
        strip.dataSource = self
        strip.delegate = self
        strip.isSelectable = true
        strip.allowsMultipleSelection = true
        strip.backgroundColors = [.clear]
        strip.register(GalleryThumbItem.self, forItemWithIdentifier: GalleryThumbItem.id)
        strip.onDoubleClick = { [weak self] in self?.pane?.open(self?.selectedItems ?? []) }
        strip.onFocusChange = { [weak self] in
            for case let item as GalleryThumbItem in self?.strip.visibleItems() ?? [] { item.updateAppearance() }
        }
        strip.onDragExit = { [weak self] in self?.springLoader.cancel() }
        strip.registerForDraggedTypes(DragSupport.types)
        strip.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        stripScroll.documentView = strip
        stripScroll.drawsBackground = false
        stripScroll.hasHorizontalScroller = true
        stripScroll.autohidesScrollers = true
        stripScroll.translatesAutoresizingMaskIntoConstraints = false
        stripScroll.automaticallyAdjustsContentInsets = false

        inspector.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        for v in [preview, stripScroll, divider, inspector] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 24),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            preview.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -24),
            preview.bottomAnchor.constraint(equalTo: stripScroll.topAnchor, constant: -16),

            stripScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stripScroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            stripScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            stripScroll.heightAnchor.constraint(equalToConstant: 72),

            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),

            inspector.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 240),
        ])
        view = root
    }

    var focusView: NSView { strip }

    func display(_ newItems: [FileItem], select refs: [ItemRef]?) {
        items = newItems
        strip.reloadData()
        if let refs, !refs.isEmpty { select(refs) }
        if strip.selectionIndexPaths.isEmpty, !items.isEmpty {
            strip.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        }
        updatePreview()
        pane?.selectionDidChange()
    }

    var selectedItems: [FileItem] {
        strip.selectionIndexPaths.sorted().compactMap { $0.item < items.count ? items[$0.item] : nil }
    }

    func select(_ refs: [ItemRef]) {
        let paths = Set(items.enumerated().filter { refs.contains($0.element.ref) }.map { IndexPath(item: $0.offset, section: 0) })
        guard !paths.isEmpty else { return }
        strip.selectionIndexPaths = paths
        strip.scrollToItems(at: paths, scrollPosition: .centeredHorizontally)
        updatePreview()
    }

    func beginRename(_ ref: ItemRef) {
        if let item = items.first(where: { $0.ref == ref }) { pane?.promptRename(item) }
    }

    private func updatePreview() {
        guard let item = selectedItems.last else {
            preview.image = nil
            inspector.show(nil)
            return
        }
        preview.image = item.icon
        Thumbnails.shared.thumbnail(for: item, size: 1024) { [weak self] image in
            guard self?.selectedItems.last?.ref == item.ref else { return }
            self?.preview.image = image
        }
        inspector.show(item)
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: GalleryThumbItem.id, for: indexPath) as! GalleryThumbItem
        cell.configure(items[indexPath.item], collection: strip)
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updatePreview()
        pane?.selectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updatePreview()
        pane?.selectionDidChange()
    }

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
        return DragSupport.operation(for: draggingInfo, destination: destination)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        springLoader.cancel()
        var destination = pane?.location.ref
        if dropOperation == .on, indexPath.item < items.count, items[indexPath.item].isBrowsable { destination = items[indexPath.item].ref }
        guard let destination else { return false }
        return DragSupport.accept(draggingInfo, destination: destination, window: view.window)
    }
}

final class GalleryThumbItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("GalleryThumb")
    private let background = NSView()
    private let icon = NSImageView()
    private var item: FileItem?
    private weak var collection: FileCollectionView?

    override func loadView() {
        let root = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        icon.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(background)
        root.addSubview(icon)
        view = root
    }

    override var isSelected: Bool { didSet { updateAppearance() } }

    func configure(_ item: FileItem, collection: FileCollectionView) {
        self.item = item
        self.collection = collection
        icon.image = item.icon
        icon.alphaValue = item.isHidden ? 0.5 : 1
        Thumbnails.shared.thumbnail(for: item, size: 60) { [weak self] image in
            guard self?.item?.ref == item.ref else { return }
            self?.icon.image = image
        }
        updateAppearance()
    }

    func updateAppearance() {
        background.layer?.backgroundColor = isSelected ? NSColor.unemphasizedSelectedContentBackgroundColor.cgColor : nil
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        background.frame = view.bounds
        icon.frame = view.bounds.insetBy(dx: 6, dy: 6)
    }
}

final class GalleryInspector: NSView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let info = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [name, detail])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let header = NSStackView(views: [icon, titles])
        header.spacing = 10
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 8
        let stack = NSStackView(views: [header, info])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 26
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            info.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            titles.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: FileItem?) {
        isHidden = item == nil
        guard let item else { return }
        icon.image = item.icon
        name.stringValue = item.displayName
        detail.stringValue = item.size.map { "\(item.kind) - \(Fmt.size($0))" } ?? item.kind
        info.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = NSTextField(labelWithString: "Information")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        info.addArrangedSubview(header)
        for (title, date) in [("Created", item.created), ("Modified", item.modified), ("Last opened", item.lastOpened)] {
            guard let date else { continue }
            let row = InfoRow(title: title, value: Fmt.longDate.string(from: date))
            info.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: info.widthAnchor).isActive = true
            let sep = NSBox()
            sep.boxType = .separator
            info.addArrangedSubview(sep)
            sep.widthAnchor.constraint(equalTo: info.widthAnchor).isActive = true
        }
        if !item.tags.isEmpty {
            let tags = NSTextField(labelWithString: "Tags")
            tags.font = .systemFont(ofSize: 13, weight: .semibold)
            info.addArrangedSubview(tags)
            info.addArrangedSubview(NSTextField(labelWithString: item.tags.joined(separator: ", ")))
        }
    }
}
