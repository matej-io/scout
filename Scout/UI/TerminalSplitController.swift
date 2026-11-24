import AppKit

/// Frame-managed split: the browser's nested split view must not contribute
/// Auto Layout constraints that pin the terminal to its minimum height.
final class TerminalSplitController: NSViewController, NSSplitViewDelegate {
    let splitView = TerminalDividerSplitView()
    private var changingLayout = false
    private var browser: NSViewController?
    private var panel: NSViewController?
    private(set) var terminalHeight: CGFloat = 240
    var isTerminalVisible: Bool { panel != nil }

    override func loadView() {
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.onDrag = { [weak self] y in
            guard let self else { return }
            self.terminalHeight = min(max(100, self.splitView.bounds.height - y - self.splitView.dividerThickness),
                                      max(100, self.splitView.bounds.height - 160))
            self.layoutPanels()
        }
        view = splitView
    }

    func setBrowser(_ controller: NSViewController) {
        loadViewIfNeeded()
        browser = controller
        addChild(controller)
        splitView.addArrangedSubview(controller.view)
        layoutPanels()
    }

    func show(_ controller: NSViewController) {
        guard panel !== controller else { return }
        hide()
        changingLayout = true
        defer { changingLayout = false }
        panel = controller
        addChild(controller)
        splitView.addArrangedSubview(controller.view)
        layoutPanels()
    }

    func hide() {
        guard let panel else { return }
        terminalHeight = panel.view.frame.height
        changingLayout = true
        defer { changingLayout = false }
        panel.view.removeFromSuperview()
        panel.removeFromParent()
        self.panel = nil
        layoutPanels()
    }

    private func layoutPanels() {
        let wasChanging = changingLayout
        changingLayout = true
        defer { changingLayout = wasChanging }
        let bounds = splitView.bounds
        guard let browser else { return }
        guard let panel else { browser.view.frame = bounds; return }
        let height = min(terminalHeight, max(100, bounds.height - 160))
        let top = max(0, bounds.height - height - splitView.dividerThickness)
        browser.view.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        panel.view.frame = NSRect(x: 0, y: top + splitView.dividerThickness, width: bounds.width, height: height)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        layoutPanels()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        160
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(160, splitView.bounds.height - 100 - splitView.dividerThickness)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        if !changingLayout, let panel, panel.view.frame.height >= 100 {
            terminalHeight = panel.view.frame.height
        }
    }

    // Give the one-point divider a comfortable drag target.
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                   forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        drawnRect.insetBy(dx: 0, dy: -4)
    }
}

/// Own the horizontal divider's tracking so nested split views cannot consume
/// the drag or restore their old frames during NSSplitView's default tracking.
final class TerminalDividerSplitView: NSSplitView {
    var onDrag: ((CGFloat) -> Void)?
    private var dragRect: NSRect {
        guard arrangedSubviews.count == 2 else { return .zero }
        return NSRect(x: 0, y: arrangedSubviews[0].frame.maxY - 4,
                      width: bounds.width, height: dividerThickness + 8)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if arrangedSubviews.count == 2, dragRect.contains(local) { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if arrangedSubviews.count == 2 { addCursorRect(dragRect, cursor: .resizeUpDown) }
    }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        guard arrangedSubviews.count == 2, dragRect.contains(start), let window else {
            super.mouseDown(with: event)
            return
        }
        let offset = start.y - arrangedSubviews[0].frame.maxY
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            onDrag?(point.y - offset)
            window.displayIfNeeded()
            if next.type == .leftMouseUp { break }
        }
        window.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }
}
