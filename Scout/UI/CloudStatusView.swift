import AppKit

/// Draws Finder's iCloud badges: a cloud symbol, or a pie chart that fills as a transfer progresses.
enum CloudBadge {
    /// `size` is the badge's height in points, about the height of the name's text.
    static func width(for size: CGFloat) -> CGFloat { (size * 1.3).rounded() }

    static func draw(_ status: CloudStatus, fraction: Double?, in rect: NSRect, color: NSColor) {
        if let name = status.symbolName {
            let config = NSImage.SymbolConfiguration(pointSize: rect.height * 0.92, weight: .regular)
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: status.toolTip(fraction: nil))?
                .withSymbolConfiguration(config) else { return }
            // Resolve the colour for the appearance being drawn now; the image draws its contents later.
            let tint = color.usingColorSpace(.sRGB) ?? color
            let image = NSImage(size: symbol.size, flipped: false) { bounds in
                symbol.draw(in: bounds)
                tint.set()
                bounds.fill(using: .sourceIn)
                return true
            }
            let size = image.size
            let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            image.draw(in: target.integral, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        guard status.isTransfer else { return }
        // Finder's transfer pie: a thin ring, filled clockwise from the top as the transfer goes on.
        let diameter = (rect.height * 0.86).rounded()
        let circle = NSRect(x: (rect.midX - diameter / 2).rounded(), y: (rect.midY - diameter / 2).rounded(), width: diameter, height: diameter)
        color.set()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
        let value = max(0, min(1, fraction ?? 0))
        guard value > 0 else { return }
        let center = NSPoint(x: circle.midX, y: circle.midY)
        let radius = diameter / 2 - 2
        let pie = NSBezierPath()
        if value >= 1 {
            pie.appendOval(in: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        } else {
            // In a flipped view clockwise on screen is the other way round.
            let flipped = NSGraphicsContext.current?.isFlipped ?? false
            let start: CGFloat = flipped ? -90 : 90
            let end = flipped ? start + 360 * value : start - 360 * value
            pie.move(to: center)
            pie.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: !flipped)
            pie.close()
        }
        pie.fill()
    }
}

/// The badge beside an item's name in list and icon view. It keeps itself up to date through `CloudMonitor`,
/// and a click on the cloud of an item that's only in iCloud downloads it, like in Finder.
final class CloudStatusView: NSControl {
    private(set) var item: FileItem?
    private var key: String?
    private var status: CloudStatus?
    private var fraction: Double?
    /// Draw in the selected-row text colour.
    var emphasized = false { didSet { if emphasized != oldValue { needsDisplay = true } } }
    var onChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(cloudChanged(_:)), name: CloudMonitor.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { CloudMonitor.shared.stopObserving(owner: self) }

    /// True when there's a badge to show.
    var hasBadge: Bool { status?.showsBadge == true }

    func configure(_ item: FileItem?) {
        self.item = item
        key = item?.ref.localURL.map(CloudMonitor.key)
        if let item, item.cloud != nil {
            CloudMonitor.shared.observe(item, owner: self)
        } else {
            CloudMonitor.shared.stopObserving(owner: self)
        }
        refresh()
    }

    @objc private func cloudChanged(_ note: Notification) {
        guard let key, note.object as? String == key else { return }
        let before = hasBadge
        refresh()
        if hasBadge != before { onChange?() }
    }

    private func refresh() {
        status = item.flatMap { CloudMonitor.shared.status(for: $0) }
        fraction = item.flatMap { CloudMonitor.shared.fraction(for: $0) }
        isHidden = !hasBadge
        toolTip = status?.toolTip(fraction: fraction)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let status, status.showsBadge else { return }
        let color: NSColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        CloudBadge.draw(status, fraction: fraction, in: bounds, color: color)
    }

    // Only the download cloud takes clicks; everywhere else the click goes to the row or icon underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        status?.canDownload == true ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let url = item?.ref.localURL, status?.canDownload == true else { return }
        CloudMonitor.shared.download([url])
    }
}
