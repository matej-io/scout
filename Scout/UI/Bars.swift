import AppKit

// MARK: - Status bar

final class StatusBarView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let activityLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    // Finder's icon size slider is non-linear; a square-root scale puts 64pt about a quarter of the way along.
    private let slider = NSSlider(value: 8, minValue: 4, maxValue: 512.squareRoot(), target: nil, action: nil)
    private let separator = NSBox()
    var onIconSizeChange: ((CGFloat) -> Void)?

    var text: String = "" { didSet { label.stringValue = text } }
    var activity: String? {
        didSet {
            activityLabel.stringValue = activity ?? ""
            activityLabel.isHidden = activity == nil
            if activity == nil { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
        }
    }
    var showsSlider = false { didSet { slider.isHidden = !showsSlider } }
    var iconSize: CGFloat {
        get { CGFloat(slider.doubleValue * slider.doubleValue) }
        set { slider.doubleValue = Double(newValue).squareRoot() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        activityLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        activityLabel.textColor = .secondaryLabelColor
        activityLabel.lineBreakMode = .byTruncatingMiddle
        activityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        activityLabel.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isHidden = true
        for v in [separator, label, activityLabel, spinner, slider] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: activityLabel.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: slider.leadingAnchor, constant: -8),
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            activityLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: 80),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func sliderChanged() {
        onIconSizeChange?(CGFloat((slider.doubleValue * slider.doubleValue).rounded()))
    }
}

// MARK: - Path bar

final class PathBarView: NSView {
    private let pathControl = NSPathControl()
    private let separator = NSBox()
    var onNavigate: ((ItemRef) -> Void)?
    private var refs: [ItemRef] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathControl.backgroundColor = .clear
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(clicked)
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [separator, pathControl] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            pathControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            pathControl.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ ref: ItemRef?, fallbackTitle: String) {
        var chain: [ItemRef] = []
        var current = ref
        while let c = current {
            chain.insert(c, at: 0)
            current = c.parent
        }
        // Finder starts local paths at the startup disk.
        refs = chain
        let small = NSSize(width: 16, height: 16)
        pathControl.pathItems = chain.map { r in
            let item = NSPathControlItem()
            let icon: NSImage
            switch r {
            case .local(let url):
                item.title = r.parent == nil ? Location.volumeName(url) : FileManager.default.displayName(atPath: url.path)
                icon = NSWorkspace.shared.icon(forFile: url.path)
            case .remote(let host, let path):
                if path == "/" {
                    item.title = SSHManager.shared.host(host).displayName
                    icon = NetworkBrowser.serverIcon
                } else {
                    item.title = (path as NSString).lastPathComponent
                    icon = FileItem(ref: r, name: item.title, isDirectory: true, isHidden: false, size: nil, modified: nil, kind: "").icon
                }
            }
            let copy = icon.copy() as! NSImage
            copy.size = small
            item.image = copy
            return item
        }
        if chain.isEmpty {
            let item = NSPathControlItem()
            item.title = fallbackTitle
            pathControl.pathItems = [item]
        }
    }

    @objc private func clicked() {
        guard let clicked = pathControl.clickedPathItem, let index = pathControl.pathItems.firstIndex(of: clicked), index < refs.count else { return }
        let ref = refs[index]
        if index == refs.count - 1, case .local(let url) = ref,
           (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            return
        }
        onNavigate?(ref)
    }
}

// MARK: - AirDrop

final class AirDropView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        icon.image = Symbols.image("airdrop", size: 96, weight: .thin)
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: "AirDrop lets you share instantly with people nearby.")
        title.font = .systemFont(ofSize: 13)
        title.textColor = .secondaryLabelColor
        let button = NSButton(title: "Open AirDrop in Finder", target: self, action: #selector(openFinderAirDrop))
        button.bezelStyle = .push
        let hint = NSTextField(wrappingLabelWithString: "Drag files onto a person in AirDrop, or select files and choose Share › AirDrop.")
        hint.alignment = .center
        hint.textColor = .tertiaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [icon, title, hint, button])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func openFinderAirDrop() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"))
    }
}

// MARK: - Get Info

final class InfoPanelController: NSWindowController, NSWindowDelegate {
    private static var open: [InfoPanelController] = []

    static func show(_ item: FileItem) {
        let controller = InfoPanelController(item: item)
        open.append(controller)
        controller.showWindow(nil)
    }

    private let item: FileItem
    private let sizeLabel = NSTextField(labelWithString: "")

    init(item: FileItem) {
        self.item = item
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 420),
                            styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "\(item.displayName) Info"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        build()
        panel.center()
        let offset = CGFloat(InfoPanelController.open.count % 8) * 22
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x + offset, y: panel.frame.origin.y - offset))
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        InfoPanelController.open.removeAll { $0 === self }
    }

    private func row(_ title: String, _ value: String) -> NSView {
        let t = NSTextField(labelWithString: title + ":")
        t.alignment = .right
        t.font = .systemFont(ofSize: 11, weight: .medium)
        t.textColor = .secondaryLabelColor
        t.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let v = NSTextField(wrappingLabelWithString: value)
        v.font = .systemFont(ofSize: 11)
        v.isSelectable = true
        let stack = NSStackView(views: [t, v])
        stack.alignment = .firstBaseline
        stack.spacing = 6
        return stack
    }

    private func build() {
        let icon = NSImageView(image: item.icon)
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let name = NSTextField(wrappingLabelWithString: item.displayName)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let modified = NSTextField(labelWithString: "Modified: " + Fmt.dateString(item.modified))
        modified.font = .systemFont(ofSize: 11)
        modified.textColor = .secondaryLabelColor
        let nameStack = NSStackView(views: [name, sizeLabel, modified])
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = 2
        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.stringValue = Fmt.size(item.size)
        let header = NSStackView(views: [icon, nameStack])
        header.alignment = .top
        header.spacing = 10

        let general = NSTextField(labelWithString: "General")
        general.font = .systemFont(ofSize: 11, weight: .bold)

        var whereText = item.ref.parent?.path ?? "/"
        if case .remote(let host, _) = item.ref { whereText = "\(SSHManager.shared.host(host).displayName):\(whereText)" }

        var rows: [NSView] = [
            row("Kind", item.kind),
            row("Size", item.isDirectory && !item.isPackage ? "Calculating…" : sizeDetail(item.size)),
            row("Where", whereText),
            row("Created", item.created.map { Fmt.longDate.string(from: $0) } ?? "--"),
            row("Modified", item.modified.map { Fmt.longDate.string(from: $0) } ?? "--"),
        ]
        if !item.tags.isEmpty { rows.append(row("Tags", item.tags.joined(separator: ", "))) }
        let sizeRow = rows[1]

        let stack = NSStackView(views: [header, NSBox.separator(), general] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSVisualEffectView()
        content.material = .windowBackground
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        window?.contentView = content

        if item.isDirectory && !item.isPackage || item.isPackage {
            computeFolderSize { [weak self] text in
                guard let self else { return }
                if let field = (sizeRow as? NSStackView)?.arrangedSubviews.last as? NSTextField { field.stringValue = text }
                self.sizeLabel.stringValue = text.components(separatedBy: " (").first ?? text
            }
        }
    }

    private func sizeDetail(_ size: Int64?) -> String {
        guard let size else { return "--" }
        let formatted = NumberFormatter.grouped.string(from: NSNumber(value: size)) ?? "\(size)"
        return "\(Fmt.size(size)) (\(formatted) bytes)"
    }

    private func computeFolderSize(_ completion: @escaping (String) -> Void) {
        switch item.ref {
        case .local(let url):
            DispatchQueue.global(qos: .utility).async {
                var total: Int64 = 0
                var count = 0
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey], options: [], errorHandler: nil)
                while let f = e?.nextObject() as? URL {
                    let v = try? f.resourceValues(forKeys: [.fileSizeKey])
                    total += Int64(v?.fileSize ?? 0)
                    count += 1
                }
                let text = "\(self.sizeDetail(total)) for \(count) items"
                DispatchQueue.main.async { completion(text) }
            }
        case .remote(let host, let path):
            SSHManager.shared.host(host).run("du -sk -- \(shq(path)) 2>/dev/null | cut -f1; find \(shq(path)) 2>/dev/null | wc -l") { result in
                guard case .success(let data) = result else { completion("--"); return }
                let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                let kb = Int64(lines.first ?? "") ?? 0
                let count = max(0, (Int(lines.last ?? "") ?? 1) - 1)
                completion("\(Fmt.size(kb * 1024)) on disk for \(count) items")
            }
        }
    }
}

extension NumberFormatter {
    static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
}

extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 248).isActive = true
        return box
    }
}
