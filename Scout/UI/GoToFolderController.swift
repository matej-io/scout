import AppKit

/// Finder’s Go to Folder panel (⇧⌘G): a sheet with a path field, live completions
/// as you type, recent locations, Tab completion, ↑/↓ to choose and Return to go.
/// Paths resolve on the SSH host when the active pane is remote, and `host:/path`
/// opens a folder on any SSH host.
final class GoToFolderController: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private struct Suggestion {
        let display: String     // what goes into the field
        let ref: ItemRef
        let isDirectory: Bool
        let icon: NSImage
    }

    private static var current: GoToFolderController?

    private let pane: PaneViewController
    private let completion: (Location, ItemRef?) -> Void
    private let field = GoToField()
    private let iconView = NSImageView()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var tableHeight: NSLayoutConstraint!
    private var suggestions: [Suggestion] = []
    private var remoteCache: [ItemRef: [FileItem]] = [:]
    private var pendingRemote = Set<ItemRef>()

    private static let width: CGFloat = 520
    private static let rowHeight: CGFloat = 26
    private static let maxRows = 9

    static func present(on window: NSWindow, pane: PaneViewController, completion: @escaping (Location, ItemRef?) -> Void) {
        let controller = GoToFolderController(pane: pane, completion: completion)
        current = controller
        window.beginSheet(controller.window!) { _ in current = nil }
        controller.window?.makeFirstResponder(controller.field)
        controller.refresh()
    }

    private init(pane: PaneViewController, completion: @escaping (Location, ItemRef?) -> Void) {
        self.pane = pane
        self.completion = completion
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: GoToFolderController.width, height: 60),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        super.init(window: panel)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func build() {
        iconView.image = NSWorkspace.shared.icon(for: .folder)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 15)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = pane.location.isRemote ? "Enter a path on \(remoteHostName ?? "the server")" : "Enter a path"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingHead

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("path"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = GoToFolderController.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .inset
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowDoubleClicked)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for v in [iconView, field, separator, scroll] as [NSView] { content.addSubview(v) }
        tableHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: GoToFolderController.width),
            iconView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 13),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            tableHeight,
        ])
        window?.contentView = content
        separatorView = separator
    }

    private var separatorView: NSView?

    private func resizeToFit() {
        let rows = min(suggestions.count, GoToFolderController.maxRows)
        tableHeight.constant = CGFloat(rows) * GoToFolderController.rowHeight + (rows > 0 ? 4 : 0)
        separatorView?.isHidden = rows == 0
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let size = window.contentView?.fittingSize ?? window.frame.size
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = NSSize(width: GoToFolderController.width, height: size.height)
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: Resolving paths

    private var remoteHostName: String? {
        pane.location.ref?.remoteHost.map { SSHManager.shared.host($0).displayName }
    }

    /// Splits `host:/path` from the input when the prefix is a known SSH destination.
    private func explicitHost(_ input: String) -> (host: String, path: String)? {
        guard !input.hasPrefix("/"), !input.hasPrefix("~"), let colon = input.firstIndex(of: ":") else { return nil }
        let host = String(input[..<colon])
        guard !host.isEmpty, !host.contains("/") else { return nil }
        let known = SSHManager.shared.hosts.contains { $0.destination == host } || host.contains("@")
        guard known else { return nil }
        return (host, String(input[input.index(after: colon)...]))
    }

    /// Turns what the user typed into a reference (local or remote).
    private func resolve(_ input: String) -> ItemRef? {
        if let (host, path) = explicitHost(input) {
            let home = SSHManager.shared.host(host).isConnected ? SSHManager.shared.host(host).home : "~"
            return .remote(host: host, path: expandRemote(path.isEmpty ? "~" : path, home: home, base: home))
        }
        if case .remote(let host, let base)? = pane.location.ref {
            return .remote(host: host, path: expandRemote(input, home: SSHManager.shared.host(host).home, base: base))
        }
        var path = (input as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            let base = pane.location.ref?.localURL?.path ?? Location.home.path
            path = (base as NSString).appendingPathComponent(path)
        }
        return .local(URL(fileURLWithPath: path))
    }

    private func expandRemote(_ input: String, home: String, base: String) -> String {
        if input == "~" { return home }
        if input.hasPrefix("~/") { return home + input.dropFirst(1) }
        if input.hasPrefix("/") { return input }
        return (base as NSString).appendingPathComponent(input)
    }

    /// What to show in the field for a reference, keeping the style the user typed (~, host:).
    private func display(for ref: ItemRef, isDirectory: Bool, typed: String) -> String {
        var text: String
        switch ref {
        case .local(let url):
            text = url.path
            if typed.hasPrefix("~") { text = (text as NSString).abbreviatingWithTildeInPath }
        case .remote(let host, let path):
            text = path
            let home = SSHManager.shared.host(host).home
            if typed.hasPrefix("~"), path.hasPrefix(home) { text = "~" + path.dropFirst(home.count) }
            if explicitHost(typed) != nil { text = "\(host):" + text }
        }
        if isDirectory && !text.hasSuffix("/") { text += "/" }
        return text
    }

    // MARK: Suggestions

    private func refresh() {
        let input = field.stringValue
        updateIcon(for: input)
        if input.isEmpty {
            suggestions = GoToFolderController.history.compactMap { entry in
                guard let ref = historyRef(entry) else { return nil }
                if case .local(let url) = ref, !FileManager.default.fileExists(atPath: url.path) { return nil }
                let isDir = ref.isRemote || (try? ref.localURL?.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                return Suggestion(display: entry, ref: ref, isDirectory: isDir, icon: icon(for: ref, isDirectory: isDir))
            }
            reloadTable(selectFirst: false)
            return
        }

        guard let resolved = resolve(input) else { suggestions = []; reloadTable(selectFirst: false); return }
        let endsWithSlash = input.hasSuffix("/")
        let directory = endsWithSlash ? resolved : (resolved.parent ?? resolved)
        let prefix = endsWithSlash ? "" : resolved.name
        let showHidden = Prefs.shared.showHidden || prefix.hasPrefix(".")

        let finish: ([FileItem]) -> Void = { [weak self] items in
            guard let self, self.field.stringValue == input else { return }
            var matches = items.filter { item in
                (showHidden || !item.isHidden) && (prefix.isEmpty || item.name.lowercased().hasPrefix(prefix.lowercased()))
            }
            matches.sort { a, b in
                if a.isBrowsable != b.isBrowsable { return a.isBrowsable }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            var list = matches.prefix(60).map { item in
                Suggestion(display: self.display(for: item.ref, isDirectory: item.isBrowsable, typed: input),
                           ref: item.ref, isDirectory: item.isBrowsable, icon: item.icon)
            }
            // Bare words also match recent locations, like Finder.
            if !input.contains("/") && self.explicitHost(input) == nil {
                for entry in GoToFolderController.history where (entry as NSString).lastPathComponent.lowercased().hasPrefix(input.lowercased()) {
                    guard let ref = self.historyRef(entry), !list.contains(where: { $0.ref == ref }) else { continue }
                    list.append(Suggestion(display: entry, ref: ref, isDirectory: true, icon: self.icon(for: ref, isDirectory: true)))
                }
            }
            self.suggestions = list
            self.reloadTable(selectFirst: false)
        }

        switch directory {
        case .local(let url):
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: FileItem.localKeys))?
                .compactMap(FileItem.local) ?? []
            finish(items)
        case .remote(let host, _):
            if let cached = remoteCache[directory] { finish(cached); return }
            finish([])
            guard !pendingRemote.contains(directory) else { return }
            pendingRemote.insert(directory)
            let ssh = SSHManager.shared.host(host)
            ssh.connect { [weak self] _ in
                FileService.list(directory, showHidden: true) { result in
                    guard let self else { return }
                    self.pendingRemote.remove(directory)
                    self.remoteCache[directory] = (try? result.get()) ?? []
                    self.refresh()
                }
            }
        }
    }

    private func historyRef(_ entry: String) -> ItemRef? {
        if let (host, path) = explicitHost(entry) { return .remote(host: host, path: path) }
        guard entry.hasPrefix("/") || entry.hasPrefix("~") else { return nil }
        return .local(URL(fileURLWithPath: (entry as NSString).expandingTildeInPath))
    }

    private func icon(for ref: ItemRef, isDirectory: Bool) -> NSImage {
        switch ref {
        case .local(let url): return NSWorkspace.shared.icon(forFile: url.path)
        case .remote: return FileItem(ref: ref, name: ref.name, isDirectory: isDirectory, isHidden: false, size: nil, modified: nil, kind: "").icon
        }
    }

    private func updateIcon(for input: String) {
        guard !input.isEmpty, let ref = resolve(input) else {
            iconView.image = NSWorkspace.shared.icon(for: .folder)
            return
        }
        if case .local(let url) = ref, FileManager.default.fileExists(atPath: url.path) {
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        } else if ref.isRemote {
            iconView.image = NetworkBrowser.serverIcon
        } else {
            iconView.image = NSWorkspace.shared.icon(for: .folder)
        }
    }

    private func reloadTable(selectFirst: Bool) {
        table.reloadData()
        if selectFirst && !suggestions.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        resizeToFit()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("GoRow")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingHead
            text.font = .systemFont(ofSize: 13)
            image.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(image)
            c.addSubview(text)
            c.imageView = image
            c.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                image.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let suggestion = suggestions[row]
        cell.imageView?.image = suggestion.icon
        var text = suggestion.display
        if text.count > 1, text.hasSuffix("/") { text.removeLast() }
        cell.textField?.stringValue = text
        return cell
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        // Clicking puts the path into the field so you can keep typing.
        field.stringValue = suggestions[row].display
        moveCaretToEnd()
        refresh()
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        go(to: suggestions[row])
    }

    // MARK: Keys

    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1); return true
        case #selector(NSResponder.insertTab(_:)):
            complete(); return true
        case #selector(NSResponder.insertNewline(_:)):
            commit(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(); return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { NSSound.beep(); return }
        let current = table.selectedRow
        let next = current < 0 ? (delta > 0 ? 0 : suggestions.count - 1) : max(0, min(suggestions.count - 1, current + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    /// Tab: completes the highlighted or common part of the matches; repeated Tabs step through them.
    private func complete() {
        guard !suggestions.isEmpty else { NSSound.beep(); return }
        if table.selectedRow >= 0 {
            field.stringValue = suggestions[table.selectedRow].display
        } else if suggestions.count == 1 {
            field.stringValue = suggestions[0].display
        } else {
            let names = suggestions.map(\.display)
            let common = names.dropFirst().reduce(names[0]) { prefix, name in
                String(zip(prefix, name).prefix { $0.lowercased() == $1.lowercased() }.map(\.0))
            }
            if common.count > field.stringValue.count {
                field.stringValue = common
            } else {
                field.stringValue = suggestions[0].display
            }
        }
        moveCaretToEnd()
        refresh()
    }

    private func moveCaretToEnd() {
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    private func commit() {
        if table.selectedRow >= 0 {
            go(to: suggestions[table.selectedRow])
            return
        }
        let input = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty, let ref = resolve(input) else { shake(); return }
        switch ref {
        case .local(let url):
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                finish(ref, isDirectory: isDir.boolValue, entry: input)
            } else if let match = caseInsensitiveMatch(url) {
                finish(.local(match.url), isDirectory: match.isDirectory, entry: input)
            } else if let first = suggestions.first {
                go(to: first)
            } else {
                shake()
            }
        case .remote:
            let parent = ref.parent ?? ref
            if let item = remoteCache[parent]?.first(where: { $0.name == ref.name }) {
                finish(ref, isDirectory: item.isBrowsable, entry: input)
            } else {
                // Unknown yet (not listed): treat it as a folder; the pane reports errors.
                finish(ref, isDirectory: true, entry: input)
            }
        }
    }

    /// Finder is forgiving about letter case (“~/downloads”).
    private func caseInsensitiveMatch(_ url: URL) -> (url: URL, isDirectory: Bool)? {
        var current = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                  let match = names.first(where: { $0.lowercased() == component.lowercased() }) else { return nil }
            current.appendPathComponent(match)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: current.path, isDirectory: &isDir) else { return nil }
        return (current, isDir.boolValue)
    }

    private func go(to suggestion: Suggestion) {
        finish(suggestion.ref, isDirectory: suggestion.isDirectory, entry: suggestion.display)
    }

    private func finish(_ ref: ItemRef, isDirectory: Bool, entry: String) {
        var stored = entry
        if stored.count > 1, stored.hasSuffix("/") { stored.removeLast() }
        if case .local(let url) = ref, !stored.hasPrefix("/") && !stored.hasPrefix("~") { stored = url.path }
        if case .remote(let host, let path) = ref, explicitHost(stored) == nil { stored = "\(host):\(path)" }
        GoToFolderController.remember(stored)
        close()
        if isDirectory {
            completion(.folder(ref), nil)
        } else if let parent = ref.parent {
            completion(.folder(parent), ref)
        }
    }

    override func close() {
        guard let window, let parent = window.sheetParent else { super.close(); return }
        parent.endSheet(window)
        window.orderOut(nil)
    }

    private func shake() {
        NSSound.beep()
        guard let window else { return }
        let frame = window.frame
        let animation = CAKeyframeAnimation()
        let path = CGMutablePath()
        path.move(to: frame.origin)
        for i in 0..<4 {
            path.addLine(to: CGPoint(x: frame.minX - 8, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.minX + (i == 3 ? 0 : 8), y: frame.minY))
        }
        path.addLine(to: frame.origin)
        animation.path = path
        animation.duration = 0.35
        window.animations = ["frameOrigin": animation]
        window.animator().setFrameOrigin(frame.origin)
    }

    /// Debug hook used by snapshots: types text into the open panel.
    static func debugType(_ text: String) {
        guard let controller = current else { return }
        controller.field.stringValue = text
        controller.moveCaretToEnd()
        controller.refresh()
    }

    // MARK: History (seeded from Finder's own Go to Folder history)

    static var history: [String] {
        if let stored = UserDefaults.standard.stringArray(forKey: "goToFolderHistory") { return stored }
        let finder = UserDefaults(suiteName: "com.apple.finder")?.stringArray(forKey: "GoToFieldHistory") ?? []
        return Array(finder.prefix(10))
    }

    static func remember(_ entry: String) {
        var list = history
        list.removeAll { $0 == entry }
        list.insert(entry, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: "goToFolderHistory")
    }
}

/// The path field. Keeps the caret at the end after programmatic changes.
final class GoToField: NSTextField {}
