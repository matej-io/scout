import AppKit
import GhosttyTerminal

/// One shell per Scout window/tab. Hiding the panel preserves the PTY and scrollback.
final class TerminalPanelController: NSViewController, TerminalSurfaceTitleDelegate, TerminalSurfaceCloseDelegate,
                                     TerminalSurfaceClipboardConfirmationDelegate {
    var onHide: (() -> Void)?
    var onExit: (() -> Void)?
    private let folder: ItemRef
    private let titleLabel = NSTextField(labelWithString: "Terminal")
    private var terminal: TerminalView?
    private let engine = TerminalController { builder in
        builder.withFontSize(13)
        // These shortcuts belong to Scout, even when the terminal has focus.
        for key in ["super+j", "super+alt+j", "super+t", "super+n", "super+q"] {
            builder.withCustom("keybind", "\(key)=unbind")
        }
    }

    init(folder: ItemRef) {
        self.folder = folder
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let hide = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide Terminal")!,
                            target: self, action: #selector(hidePanel))
        hide.bezelStyle = .inline
        hide.isBordered = false
        hide.toolTip = "Hide Terminal (⌘J). The shell keeps running."
        let terminal = TerminalView(frame: .zero)
        terminal.setAccessibilityLabel("Terminal")
        terminal.setAccessibilityIdentifier("scout.terminal")
        terminal.delegate = self
        switch folder {
        case .local(let url):
            terminal.configuration = TerminalSurfaceOptions(workingDirectory: url.path)
            titleLabel.stringValue = "Terminal — \(url.lastPathComponent)"
        case .remote(let host, let path):
            let command = (path.isEmpty ? "" : "cd \(shq(path)) && ") + "exec \"$SHELL\" -l"
            terminal.configuration = TerminalSurfaceOptions(
                command: "/usr/bin/ssh -t -- \(shq(host)) \(shq(command))", waitAfterCommand: true)
            titleLabel.stringValue = "Terminal — \(host)"
        }
        terminal.controller = engine
        self.terminal = terminal
        for child in [titleLabel, hide, terminal] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: hide.leadingAnchor, constant: -8),
            hide.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            hide.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            hide.widthAnchor.constraint(equalToConstant: 20),
            hide.heightAnchor.constraint(equalToConstant: 20),
            terminal.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
            terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        terminal?.fitToSize()
    }

    func focus() { view.window?.makeFirstResponder(terminal) }
    func setVisible(_ visible: Bool) { terminal?.setSurfaceVisible(visible) }
    func stop() {
        terminal?.delegate = nil
        terminal?.controller = nil
        terminal?.removeFromSuperview()
        terminal = nil
    }

    @objc private func hidePanel() { onHide?() }
    func terminalDidChangeTitle(_ title: String) {
        titleLabel.stringValue = title.isEmpty ? "Terminal" : "Terminal — \(title)"
    }
    func terminalDidClose(processAlive: Bool) {
        // Release the surface after Ghostty has returned from its callback.
        DispatchQueue.main.async { [weak self] in
            if processAlive { self?.onHide?() } else { self?.onExit?() }
        }
    }
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        guard let window = view.window else { request.respond(allow: false); return }
        let alert = NSAlert()
        alert.messageText = request.kind == .paste ? "Paste into Terminal?" : "Allow terminal clipboard access?"
        alert.informativeText = "The terminal requested clipboard access or a paste that may execute commands."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            request.respond(allow: response == .alertFirstButtonReturn)
        }
    }
}
