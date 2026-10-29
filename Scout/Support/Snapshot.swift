import AppKit

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
        if let query = env["SCOUT_SEARCH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                controller.activePane.search(query)
                if let scope = env["SCOUT_SEARCH_SCOPE"].flatMap(SearchScope.init(rawValue:)) { controller.activePane.setSearchScope(scope) }
            }
        }
        if let text = env["SCOUT_GOTO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                controller.goToFolder(nil)
                if !text.isEmpty { GoToFolderController.debugType(text) }
            }
        }
        if env["SCOUT_SPLIT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { controller.toggleSplit(nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            render(controller.window!, to: path)
            if let sheet = controller.window?.attachedSheet ?? controller.window?.childWindows?.first, let view = sheet.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-sheet.png")))
            }
            if env["SCOUT_SNAPSHOT_QUIT"] == "1" { exit(0) }
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
        // Child windows (Go to Folder) drawn where they sit over the window.
        for child in window.childWindows ?? [] {
            guard let view = child.contentView?.superview ?? child.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(rep)
            let origin = NSPoint(x: child.frame.minX - window.frame.minX, y: child.frame.minY - window.frame.minY)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: NSRect(origin: origin, size: child.frame.size), xRadius: 16, yRadius: 16).fill()
            image.draw(in: NSRect(origin: origin, size: child.frame.size))
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: NSRect(origin: origin, size: child.frame.size).insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16).stroke()
        }
        composite.unlockFocus()
        guard let tiff = composite.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return }
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
