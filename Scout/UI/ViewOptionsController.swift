import AppKit

/// Finder’s View Options (⌘J): a floating panel with the settings for the view the
/// front window’s active pane is in. Sorting and Use as Defaults apply to that pane’s
/// folder; the other settings apply to every folder shown in that view.
final class ViewOptionsController: NSObject, NSWindowDelegate {
    static let shared = ViewOptionsController()

    private var panel: NSPanel?
    private weak var shownPane: PaneViewController?
    private var shownMode: ViewMode?
    private var actions: [ControlAction] = []
    private var sortPopup: NSPopUpButton?
    private var iconSizeSlider: NSSlider?
    private var iconSizeLabel: NSTextField?
    private static let width: CGFloat = 250

    private override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refresh), name: NSWindow.didBecomeMainNotification, object: nil)
        nc.addObserver(self, selector: #selector(refresh), name: NSWindow.willCloseNotification, object: nil)
        nc.addObserver(self, selector: #selector(syncValues), name: PaneViewController.iconSizeChanged, object: nil)
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible { panel?.orderOut(nil) } else { show() }
    }

    private func show() {
        guard let pane = currentPane else { return }
        let isNew = panel == nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        rebuild(for: pane)
        if isNew, !panel.setFrameUsingName("ViewOptions"), let window = pane.view.window {
            // First time: just inside the window's top-right corner, like Finder.
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(x: window.frame.maxX - frame.width - 24, y: window.frame.maxY - frame.height - 80))
        }
        panel.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: ViewOptionsController.width, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // Finder's panel only has a close button.
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }

    func windowDidMove(_ notification: Notification) {
        panel?.saveFrame(usingName: "ViewOptions")
    }

    private var currentPane: PaneViewController? {
        let window = NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.windowController is MainWindowController }
        return (window?.windowController as? MainWindowController)?.activePane
    }

    /// The front window's pane, folder or view changed.
    @objc func refresh() {
        guard isVisible else { return }
        // Let window-closing and control actions finish before the controls are replaced.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            guard let pane = self.currentPane else { self.panel?.orderOut(nil); return }
            if pane !== self.shownPane || pane.viewMode != self.shownMode {
                self.rebuild(for: pane)
            } else {
                self.syncValues()
            }
        }
    }

    @objc private func syncValues() {
        guard let pane = shownPane else { return }
        panel?.title = pane.displayTitle
        sortPopup?.selectItem(at: SortKey.optionsOrder.firstIndex(of: pane.sortKey) ?? 0)
        let size = Prefs.shared.iconSize
        iconSizeSlider?.doubleValue = Double(size).squareRoot()
        iconSizeLabel?.stringValue = "Icon size: \(Int(size))×\(Int(size))"
    }

    // MARK: Building

    private func rebuild(for pane: PaneViewController) {
        guard let panel else { return }
        shownPane = pane
        shownMode = pane.viewMode
        actions = []
        sortPopup = nil
        iconSizeSlider = nil
        iconSizeLabel = nil

        var sections: [[NSView]] = [[sortRow(pane)]]
        switch pane.viewMode {
        case .icon: sections += iconSections()
        case .list: sections += listSections()
        case .column: sections += columnSections()
        case .gallery: break
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for (index, section) in sections.enumerated() {
            if index > 0 { stack.addArrangedSubview(separator()) }
            stack.addArrangedSubview(sectionView(section))
        }
        stack.addArrangedSubview(separator())
        let defaults = NSButton(title: "Use as Defaults", target: nil, action: nil)
        bind(defaults) { [weak pane] _ in pane?.useAsDefaults() }
        let footer = NSStackView(views: [defaults])
        footer.orientation = .vertical
        footer.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        footer.alignment = .centerX
        stack.addArrangedSubview(footer)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalToConstant: ViewOptionsController.width).isActive = true
        }

        let top = panel.frame.maxY
        panel.contentView = stack
        let size = stack.fittingSize
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: panel.frame.minX, y: top - frame.height)
        panel.setFrame(frame, display: true)
        syncValues()
    }

    private func sortRow(_ pane: PaneViewController) -> NSView {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: SortKey.optionsOrder.map(\.title))
        bind(popup) { [weak pane] control in
            guard let pane, let popup = control as? NSPopUpButton else { return }
            let key = SortKey.optionsOrder[popup.indexOfSelectedItem]
            if key != pane.sortKey { pane.setSort(key, ascending: true) }
        }
        sortPopup = popup
        return row([label("Sort By:"), popup])
    }

    private func iconSections() -> [[NSView]] {
        let prefs = Prefs.shared
        let sizeLabel = label("")
        iconSizeLabel = sizeLabel
        // The same square-root scale as the status bar slider, from 16 to 512 points.
        let sizeSlider = slider(min: 4, max: 512.squareRoot(), value: Double(prefs.iconSize).squareRoot())
        bind(sizeSlider) { [weak self] control in
            let value = CGFloat((control.doubleValue * control.doubleValue).rounded())
            Prefs.shared.iconSize = value
            self?.iconSizeLabel?.stringValue = "Icon size: \(Int(value))×\(Int(value))"
            NotificationCenter.default.post(name: PaneViewController.iconSizeChanged, object: nil)
        }
        iconSizeSlider = sizeSlider
        let spacingSlider = slider(min: 4, max: 64, value: Double(prefs.iconGridSpacing))
        bind(spacingSlider) { control in Prefs.shared.iconGridSpacing = CGFloat(control.doubleValue.rounded()) }

        let labelPosition = radioRow(["Bottom", "Right"], selected: prefs.iconLabelsRight ? 1 : 0) { index in
            Prefs.shared.iconLabelsRight = index == 1
        }
        return [
            [sizeLabel,
             row([symbol("doc", 11), sizeSlider, symbol("doc", 22)]),
             label("Grid spacing:"),
             row([symbol("square.grid.2x2", 12), spacingSlider, symbol("square.grid.3x3", 20)])],
            [textSizeRow(prefs.iconTextSize) { Prefs.shared.iconTextSize = $0 },
             label("Label position:"),
             labelPosition],
            [checkbox("Show item info", prefs.iconShowInfo) { Prefs.shared.iconShowInfo = $0 },
             checkbox("Show icon preview", prefs.iconShowPreview) { Prefs.shared.iconShowPreview = $0 }],
        ]
    }

    private func listSections() -> [[NSView]] {
        let prefs = Prefs.shared
        let iconSize = radioRow(["Small", "Large"], selected: prefs.listLargeIcons ? 1 : 0) { index in
            Prefs.shared.listLargeIcons = index == 1
        }
        var columns: [NSView] = [label("Show Columns:")]
        let visible = ListContentController.visibleColumns
        for column in ListContentController.columns where column.id != "name" {
            columns.append(checkbox(column.title, visible.contains(column.id)) { on in
                var visible = ListContentController.visibleColumns
                if on { visible.insert(column.id) } else { visible.remove(column.id) }
                ListContentController.visibleColumns = visible
            })
        }
        return [
            [label("Icon size:"), iconSize],
            [textSizeRow(prefs.listTextSize) { Prefs.shared.listTextSize = $0 }],
            columns,
            [checkbox("Use relative dates", prefs.listRelativeDates) { Prefs.shared.listRelativeDates = $0 },
             checkbox("Show icon preview", prefs.listShowPreview) { Prefs.shared.listShowPreview = $0 }],
        ]
    }

    private func columnSections() -> [[NSView]] {
        let prefs = Prefs.shared
        return [
            [textSizeRow(prefs.columnTextSize) { Prefs.shared.columnTextSize = $0 }],
            [checkbox("Show icons", prefs.columnShowIcons) { Prefs.shared.columnShowIcons = $0 },
             checkbox("Show preview column", prefs.columnShowPreview) { Prefs.shared.columnShowPreview = $0 }],
        ]
    }

    // MARK: Controls

    private func bind(_ control: NSControl, _ handler: @escaping (NSControl) -> Void) {
        let action = ControlAction(handler)
        actions.append(action)
        control.target = action
        control.action = #selector(ControlAction.fire(_:))
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func sectionView(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        for view in views where view is NSStackView && (view as! NSStackView).orientation == .horizontal {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        return stack
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func symbol(_ name: String, _ size: CGFloat) -> NSImageView {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .light)
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage())
        view.contentTintColor = .secondaryLabelColor
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func slider(min: Double, max: Double, value: Double) -> NSSlider {
        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    private func checkbox(_ title: String, _ on: Bool, _ changed: @escaping (Bool) -> Void) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = on ? .on : .off
        bind(button) { changed(($0 as? NSButton)?.state == .on) }
        return button
    }

    /// Radio buttons in a row of their own, which also keeps AppKit from grouping them with other rows.
    private func radioRow(_ titles: [String], selected: Int, _ changed: @escaping (Int) -> Void) -> NSStackView {
        let buttons = titles.map { NSButton(radioButtonWithTitle: $0, target: nil, action: nil) }
        for (index, button) in buttons.enumerated() {
            button.state = index == selected ? .on : .off
            bind(button) { _ in
                for (i, other) in buttons.enumerated() { other.state = i == index ? .on : .off }
                changed(index)
            }
        }
        let stack = row(buttons)
        stack.spacing = 16
        return stack
    }

    private func textSizeRow(_ current: CGFloat, _ changed: @escaping (CGFloat) -> Void) -> NSView {
        let sizes = Array(10...16)
        let popup = NSPopUpButton()
        popup.addItems(withTitles: sizes.map(String.init))
        popup.selectItem(at: sizes.firstIndex(of: Int(current)) ?? 2)
        bind(popup) { control in
            guard let popup = control as? NSPopUpButton else { return }
            changed(CGFloat(sizes[popup.indexOfSelectedItem]))
        }
        popup.setContentHuggingPriority(.required, for: .horizontal)
        return row([label("Text size:"), popup])
    }
}

private final class ControlAction: NSObject {
    private let handler: (NSControl) -> Void
    init(_ handler: @escaping (NSControl) -> Void) { self.handler = handler }
    @objc func fire(_ sender: NSControl) { handler(sender) }
}

extension SortKey {
    /// The View Options Sort By choices.
    static let optionsOrder: [SortKey] = [.none] + menuOrder
}
