import AppKit
import GhosttyTerminal

/// A folder session owned by a Scout window/tab. Hiding the panel preserves the PTY and scrollback.
final class TerminalPanelController: NSViewController, TerminalSurfaceTitleDelegate, TerminalSurfaceCloseDelegate,
                                     TerminalSurfaceClipboardConfirmationDelegate, TerminalSurfacePwdDelegate {
    var onHide: (() -> Void)?
    var onExit: (() -> Void)?
    var onNew: (() -> Void)?
    var onSelect: ((Int) -> Void)?
    private var navigation: TerminalNavigation?
    private let sessions = NSPopUpButton(frame: .zero, pullsDown: false)
    private let folder: ItemRef
    private(set) var currentFolder: ItemRef
    private let titleLabel = NSTextField(labelWithString: "Terminal")
    private var terminal: TerminalView?
    private lazy var engine = TerminalController { builder in
        builder.withFontSize(13)
        builder.withCustom("wait-after-command", "false")
        if self.navigation != nil { builder.withCustom("shell-integration", "none") }
        // These shortcuts belong to Scout, even when the terminal has focus.
        for key in ["super+j", "super+alt+j", "super+t", "super+n", "super+q"] {
            builder.withCustom("keybind", "\(key)=unbind")
        }
    }

    init(folder: ItemRef) {
        self.folder = folder
        self.currentFolder = folder
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
        sessions.target = self
        sessions.action = #selector(selectSession)
        sessions.setAccessibilityLabel("Terminal sessions")
        let newTerminal = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Terminal Here")!,
                                   target: self, action: #selector(newSession))
        newTerminal.isBordered = false
        newTerminal.toolTip = "New Terminal Here"
        let terminal = TerminalView(frame: .zero)
        terminal.setAccessibilityLabel("Terminal")
        terminal.setAccessibilityIdentifier("scout.terminal")
        terminal.delegate = self
        switch folder {
        case .local(let url):
            let shell = ProcessInfo.processInfo.environment["SHELL"]
                ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/zsh"
            if (shell as NSString).lastPathComponent == "zsh" {
                navigation = try? TerminalNavigation()
            }
            terminal.configuration = TerminalSurfaceOptions(workingDirectory: url.path,
                envVars: navigation?.environment ?? [:], waitAfterCommand: false)
            titleLabel.stringValue = "Terminal — \(url.lastPathComponent)"
        case .remote(let host, let path):
            let command = (path.isEmpty ? "" : "cd \(shq(path)) && ") + "exec \"$SHELL\" -l"
            terminal.configuration = TerminalSurfaceOptions(
                command: "/usr/bin/ssh -t -- \(shq(host)) \(shq(command))", waitAfterCommand: false)
            titleLabel.stringValue = "Terminal — \(host)"
        }
        terminal.controller = engine
        self.terminal = terminal
        for child in [titleLabel, sessions, newTerminal, hide, terminal] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: sessions.leadingAnchor, constant: -8),
            sessions.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            sessions.widthAnchor.constraint(equalToConstant: 130),
            sessions.trailingAnchor.constraint(equalTo: newTerminal.leadingAnchor, constant: -8),
            newTerminal.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -8),
            newTerminal.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            newTerminal.widthAnchor.constraint(equalToConstant: 20),
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

    func followFolder(_ target: ItemRef) {
        guard case .local = folder, case .local(let url) = target else { return }
        navigation?.navigate(to: url)
    }

    func updateSessions(count: Int, selected: Int) {
        _ = view
        sessions.removeAllItems()
        sessions.addItems(withTitles: (1...max(1, count)).map { "Terminal \($0)" })
        sessions.selectItem(at: selected)
        sessions.isHidden = count < 2
    }

    @objc private func newSession() { onNew?() }
    @objc private func selectSession() { onSelect?(sessions.indexOfSelectedItem) }

    func focus() { view.window?.makeFirstResponder(terminal) }
    func setVisible(_ visible: Bool) { terminal?.setSurfaceVisible(visible) }
    func stop() {
        terminal?.delegate = nil
        terminal?.controller = nil
        terminal?.removeFromSuperview()
        terminal = nil
        navigation = nil
    }

    @objc private func hidePanel() { onHide?() }
    func terminalDidChangeWorkingDirectory(_ path: String) {
        let directory = path.hasPrefix("file://") ? URL(string: path)?.path : path
        guard let directory, directory.hasPrefix("/") else { return }
        titleLabel.stringValue = "Terminal — \(directory)"
        switch folder {
        case .local:
            currentFolder = .local(URL(fileURLWithPath: directory))
        case .remote(let host, _):
            currentFolder = .remote(host: host, path: directory)
        }
    }

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
