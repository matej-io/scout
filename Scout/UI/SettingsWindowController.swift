import AppKit

/// A small Finder-style settings window.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Scout Settings"
        super.init(window: window)
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func checkbox(_ title: String, _ value: Bool, _ action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = value ? .on : .off
        return button
    }

    private func build() {
        let prefs = Prefs.shared
        let general = NSTextField(labelWithString: "General")
        general.font = .boldSystemFont(ofSize: 13)
        let ssh = NSTextField(labelWithString: "SSH")
        ssh.font = .boldSystemFont(ofSize: 13)

        let keys = SSHConfig.privateKeys().map(\.lastPathComponent)
        let hosts = SSHConfig.load().map(\.alias)
        let sshInfo = NSTextField(wrappingLabelWithString:
            "Scout connects with your system ssh, so ~/.ssh/config, ProxyJump, the SSH agent and known_hosts all apply.\n\n" +
            "Hosts: \(hosts.isEmpty ? "none" : hosts.joined(separator: ", "))\n" +
            "Keys: \(keys.isEmpty ? "none" : keys.joined(separator: ", "))")
        sshInfo.font = .systemFont(ofSize: 11)
        sshInfo.textColor = .secondaryLabelColor
        sshInfo.preferredMaxLayoutWidth = 380

        let stack = NSStackView(views: [
            general,
            checkbox("Show hidden files", prefs.showHidden, #selector(toggleHidden(_:))),
            checkbox("Keep folders on top when sorting by name", prefs.foldersFirst, #selector(toggleFoldersFirst(_:))),
            checkbox("Show path bar", prefs.showPathBar, #selector(togglePath(_:))),
            checkbox("Show status bar", prefs.showStatusBar, #selector(toggleStatus(_:))),
            checkbox("Show Tags in sidebar", prefs.showTags, #selector(toggleTags(_:))),
            ssh,
            sshInfo,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[5])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window?.contentView = stack
    }

    @objc private func toggleHidden(_ sender: NSButton) { Prefs.shared.showHidden = sender.state == .on }
    @objc private func toggleFoldersFirst(_ sender: NSButton) { Prefs.shared.foldersFirst = sender.state == .on }
    @objc private func togglePath(_ sender: NSButton) { Prefs.shared.showPathBar = sender.state == .on }
    @objc private func toggleStatus(_ sender: NSButton) { Prefs.shared.showStatusBar = sender.state == .on }
    @objc private func toggleTags(_ sender: NSButton) { Prefs.shared.showTags = sender.state == .on }
}

/// Debug helper for screenshots without screen-recording permission:
/// SCOUT_SNAPSHOT=/path.png renders the first window into a PNG after launch.
/// Optional: SCOUT_START=/path or ssh:host:/path, SCOUT_VIEW=0-3, SCOUT_SPLIT=1, SCOUT_APPEARANCE=dark|light,
/// SCOUT_SNAPSHOT_DELAY=seconds, SCOUT_SNAPSHOT_QUIT=1.
enum Snapshot {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    static var startLocation: Location? {
        guard let start = env["SCOUT_START"] else { return nil }
        if start.hasPrefix("ssh:") {
            let rest = start.dropFirst(4)
            guard let colon = rest.firstIndex(of: ":") else { return .folder(.remote(host: String(rest), path: "")) }
            return .folder(.remote(host: String(rest[..<colon]), path: String(rest[rest.index(after: colon)...])))
        }
        switch start {
        case "network": return .network
        case "recents": return .recents
        case "airdrop": return .airdrop
        default: return .folder(.local(URL(fileURLWithPath: (start as NSString).expandingTildeInPath)))
        }
    }

    static func applyAppearance() {
        switch env["SCOUT_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    static func schedule(to path: String) {
        let delay = Double(env["SCOUT_SNAPSHOT_DELAY"] ?? "2.5") ?? 2.5
        guard let controller = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first else { return }
        if let mode = env["SCOUT_VIEW"].flatMap(Int.init).flatMap(ViewMode.init(rawValue:)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { controller.activePane.setViewMode(mode) }
        }
        if env["SCOUT_SPLIT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { controller.toggleSplit(nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            render(controller.window!, to: path)
            if env["SCOUT_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
        }
    }

    static func render(_ window: NSWindow, to path: String) {
        guard let frameView = window.contentView?.superview else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        // Glass/visual-effect backgrounds aren't captured by cacheDisplay, so composite the sidebar separately.
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        let composite = NSImage(size: bounds.size)
        composite.lockFocus()
        image.draw(in: bounds)
        if let sidebar = (window.contentViewController as? NSSplitViewController)?.splitViewItems.first?.viewController.view,
           !sidebar.isHiddenOrHasHiddenAncestor {
            let frame = sidebar.convert(sidebar.bounds, to: frameView)
            if env["SCOUT_DEBUG"] != nil {
                NSLog("sidebar frame %@ in frame view %@ flipped %d", NSStringFromRect(frame), NSStringFromRect(bounds), frameView.isFlipped ? 1 : 0)
                var v: NSView? = sidebar
                while let cur = v { NSLog("  %@ %@ hidden=%d alpha=%.2f", String(describing: type(of: cur)), NSStringFromRect(cur.frame), cur.isHidden ? 1 : 0, cur.alphaValue); v = cur.superview }
                if let doc = (sidebar as? NSScrollView)?.documentView { NSLog("doc %@ subviews %d", NSStringFromRect(doc.frame), doc.subviews.count) }
            }
            let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            let flipped = NSRect(x: frame.minX, y: frameView.isFlipped ? bounds.height - frame.maxY : frame.minY, width: frame.width, height: frame.height)
            NSRect(x: 0, y: 0, width: flipped.maxX, height: bounds.height).fill()
            if let sideRep = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds) {
                sidebar.cacheDisplay(in: sidebar.bounds, to: sideRep)
                let sideImage = NSImage(size: sidebar.bounds.size)
                sideImage.addRepresentation(sideRep)
                sideImage.draw(in: flipped)
            }
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let b = window.standardWindowButton(button) else { continue }
                let f = b.convert(b.bounds, to: frameView)
                let color: NSColor = button == .closeButton ? .systemRed : (button == .miniaturizeButton ? .systemYellow : .systemGreen)
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: f.minX, y: frameView.isFlipped ? bounds.height - f.maxY : f.minY, width: f.width, height: f.height).insetBy(dx: 1, dy: 1)).fill()
            }
        }
        composite.unlockFocus()
        guard let tiff = composite.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return }
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
