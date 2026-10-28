import AppKit

/// macOS has no API to request Full Disk Access, so Scout checks whether it can read a file only
/// Full Disk Access unlocks and, if not, explains how to turn it on in System Settings. Asking at
/// first launch, before any window lists Desktop, Documents or Downloads, spares the user a
/// separate prompt for each of those folders and every external disk.
enum FullDiskAccess {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let skippedKey = "fullDiskAccessSkipped"

    static var isGranted: Bool {
        let tcc = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(tcc, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        if errno != ENOENT { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Safari")) != nil
    }

    static var shouldAskAtLaunch: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["SCOUT_FDA"] == "1" { return true }
        if ["SCOUT_SNAPSHOT", "SCOUT_SELFTEST", "SCOUT_SPRINGTEST"].contains(where: { env[$0] != nil }) { return false }
        return !UserDefaults.standard.bool(forKey: skippedKey) && !isGranted
    }

    static func openSettings() { NSWorkspace.shared.open(settingsURL) }
}

/// The window that walks the user through turning on Full Disk Access.
final class FullDiskAccessController: NSWindowController, NSWindowDelegate {
    private static var current: FullDiskAccessController?

    private var completion: (() -> Void)?
    private var timer: Timer?

    private static let width: CGFloat = 480
    private static let textWidth: CGFloat = 360   // leaves 60 pt either side

    /// Shows the window. `completion` runs once, when access is granted or the user chooses Not Now.
    static func present(completion: (() -> Void)? = nil) {
        if let current {
            current.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = FullDiskAccessController(completion: completion)
        current = controller
        controller.window?.center()
        controller.showWindow(nil)
        NSApp.activate()
        if let path = ProcessInfo.processInfo.environment["SCOUT_SNAPSHOT"], ProcessInfo.processInfo.environment["SCOUT_FDA"] == "1" {
            Snapshot.applyAppearance()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let view = controller.window?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                exit(0)
            }
        }
    }

    private init(completion: (() -> Void)?) {
        self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Full Disk Access"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccess() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let icon = AppIconDragView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 96), icon.heightAnchor.constraint(equalToConstant: 96)])

        let title = NSTextField(labelWithString: "Give Scout Full Disk Access")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString:
            "Like Finder, Scout can then show every folder on your Mac, including the \(Prefs.trashTitle), " +
            "and macOS won’t stop to ask separately about your Desktop, Documents, Downloads and each external disk.")
        body.alignment = .center
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = FullDiskAccessController.textWidth

        let steps = NSStackView(views: [
            step(1, "Click Open System Settings."),
            step(2, "Turn on Scout under Full Disk Access. If Scout isn’t in the list, drag the icon above into it."),
            step(3, "If macOS asks, click Quit & Reopen."),
        ])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 10

        let later = NSButton(title: "Not Now", target: self, action: #selector(notNow(_:)))
        later.keyEquivalent = "\u{1b}"
        let open = NSButton(title: "Open System Settings", target: self, action: #selector(openSettings(_:)))
        open.keyEquivalent = "\r"
        let buttons = NSStackView(views: [later, open])
        buttons.spacing = 12

        let footer = NSTextField(labelWithString: "You can do this later in Scout › Settings.")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [icon, title, body, steps, buttons, footer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(8, after: icon)
        stack.setCustomSpacing(20, after: body)
        stack.setCustomSpacing(24, after: steps)
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 0, bottom: 24, right: 0)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: FullDiskAccessController.width),
            body.widthAnchor.constraint(equalToConstant: FullDiskAccessController.textWidth),
            steps.widthAnchor.constraint(equalToConstant: FullDiskAccessController.textWidth),
        ])
        window?.contentView = stack
        window?.setContentSize(stack.fittingSize)
    }

    private func step(_ number: Int, _ text: String) -> NSView {
        let badge = NSImageView(image: NSImage(systemSymbolName: "\(number).circle.fill", accessibilityDescription: "\(number)")!)
        badge.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        badge.contentTintColor = .controlAccentColor
        badge.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = FullDiskAccessController.textWidth - 25
        let row = NSStackView(views: [badge, label])
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func checkAccess() {
        guard FullDiskAccess.isGranted else { return }
        UserDefaults.standard.removeObject(forKey: FullDiskAccess.skippedKey)
        close()
    }

    @objc private func openSettings(_ sender: Any?) { FullDiskAccess.openSettings() }

    @objc private func notNow(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        if !FullDiskAccess.isGranted { UserDefaults.standard.set(true, forKey: FullDiskAccess.skippedKey) }
        let done = completion
        completion = nil
        FullDiskAccessController.current = nil
        done?()
    }
}

/// The app icon, which can be dragged into the Full Disk Access list when Scout isn’t listed yet.
private final class AppIconDragView: NSImageView, NSDraggingSource {
    init() {
        super.init(frame: .zero)
        image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        imageScaling = .scaleProportionallyUpOrDown
        isEditable = false
        unregisterDraggedTypes()
        toolTip = "Drag Scout into the Full Disk Access list"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
