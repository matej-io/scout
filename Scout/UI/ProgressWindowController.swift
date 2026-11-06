import AppKit

/// Finder's copy window: one row per running copy or move, with a progress bar, how much is done,
/// the time left and a stop button. A transfer only appears once it has run for `showDelay`,
/// so quick copies never flash a window.
final class ProgressWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ProgressWindowController()
    /// Long enough that everyday copies finish first, short enough that a big one isn't left looking stuck.
    static let showDelay: TimeInterval = 1.0

    private let stack = NSStackView()
    private var rows: [ProgressRowView] = []
    private var timer: Timer?
    private var placed = false
    private static let width: CGFloat = 460

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: ProgressWindowController.width, height: 80),
                            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: ProgressWindowController.width),
        ])
        panel.contentView = content
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Call when a transfer starts. Its row appears if it's still running after `showDelay`.
    func track(_ progress: TransferProgress) {
        DispatchQueue.main.asyncAfter(deadline: .now() + ProgressWindowController.showDelay) { [weak self, weak progress] in
            guard let self, let progress, !progress.isFinished else { return }
            self.add(progress)
        }
    }

    /// Call when a transfer ends, however it ended.
    func finished(_ progress: TransferProgress) {
        guard let index = rows.firstIndex(where: { $0.progress === progress }) else { return }
        let row = rows.remove(at: index)
        row.removeFromSuperview()
        if rows.isEmpty {
            timer?.invalidate()
            timer = nil
            window?.orderOut(nil)
        } else {
            layoutRows()
        }
    }

    private func add(_ progress: TransferProgress) {
        let row = ProgressRowView(progress: progress)
        rows.append(row)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        layoutRows()
        row.refresh()
        if timer == nil {
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.rows.forEach { $0.refresh() } }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        guard let window else { return }
        if !placed {
            placed = true
            // First time, centre it near the top of the window being worked in, like Finder.
            if let main = NSApp.mainWindow ?? NSApp.keyWindow {
                let f = main.frame
                window.setFrameTopLeftPoint(NSPoint(x: f.midX - window.frame.width / 2, y: f.maxY - 120))
            } else {
                window.center()
            }
        }
        if !window.isVisible { window.orderFront(nil) }
    }

    private func layoutRows() {
        for (i, row) in rows.enumerated() { row.showsSeparator = i > 0 }
        let moves = rows.filter { $0.progress.move }.count
        window?.title = moves == 0 ? "Copy" : moves == rows.count ? "Move" : "Copy and Move"
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        let top = window.frame.maxY
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: ProgressWindowController.width, height: height))
        frame.origin = NSPoint(x: window.frame.minX, y: top - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    // Closing the window only hides it; the transfers carry on.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private final class ProgressRowView: NSView {
    let progress: TransferProgress
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let stopButton = NSButton()
    private let separator = NSBox()
    private var determinate: Bool?

    var showsSeparator = false { didSet { separator.isHidden = !showsSeparator } }

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let duration: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.maximumUnitCount = 1
        f.allowedUnits = [.hour, .minute, .second]
        return f
    }()

    init(progress: TransferProgress) {
        self.progress = progress
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = progress.title
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .regular
        stopButton.image = Symbols.image("xmark.circle.fill", size: 15)
        stopButton.isBordered = false
        stopButton.contentTintColor = .secondaryLabelColor
        stopButton.toolTip = "Stop"
        stopButton.target = self
        stopButton.action = #selector(stop)
        separator.boxType = .separator
        separator.isHidden = true

        for v in [titleLabel, detailLabel, bar, stopButton, separator] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stopButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            stopButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stopButton.widthAnchor.constraint(equalToConstant: 18),
            stopButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func stop() {
        stopButton.isEnabled = false
        progress.cancel()
        refresh()
    }

    func refresh() {
        let done = progress.completed
        let total = progress.total.flatMap { $0 > 0 ? $0 : nil }
        let isDeterminate = total != nil && !progress.isCancelled
        if determinate != isDeterminate {
            determinate = isDeterminate
            bar.isIndeterminate = !isDeterminate
            if isDeterminate { bar.stopAnimation(nil) } else { bar.startAnimation(nil) }
        }
        if let total, isDeterminate { bar.doubleValue = min(1, Double(done) / Double(total)) }
        detailLabel.stringValue = detail(done: done, total: total)
    }

    private func detail(done: Int64, total: Int64?) -> String {
        if progress.isCancelled { return "Stopping…" }
        guard let total else {
            return done > 0 ? "\(Self.bytes.string(fromByteCount: done)) \(progress.move ? "moved" : "copied")" : "Preparing…"
        }
        let amount = "\(Self.bytes.string(fromByteCount: min(done, total))) of \(Self.bytes.string(fromByteCount: total))"
        guard let remaining = timeRemaining(done: done, total: total) else { return amount }
        return "\(amount) — \(remaining)"
    }

    /// Finder-style estimate: whole minutes or hours, seconds in fives, nothing until there's a rate to go on.
    private func timeRemaining(done: Int64, total: Int64) -> String? {
        let elapsed = Date().timeIntervalSince(progress.started)
        guard elapsed > 2, done > 0, done < total else { return nil }
        var seconds = Double(total - done) / (Double(done) / elapsed)
        if seconds < 60 { seconds = max(5, (seconds / 5).rounded(.up) * 5) } else { seconds = (seconds / 60).rounded() * 60 }
        guard let text = Self.duration.string(from: seconds) else { return nil }
        return "About \(text)"
    }
}
