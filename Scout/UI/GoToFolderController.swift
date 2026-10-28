import AppKit

/// Go to Folder (⌘L, or Finder’s ⇧⌘G): a sheet with a path field that opens on the current
/// folder’s absolute path, selected like a browser’s address bar. It behaves like a shell:
/// paths can be absolute, relative to the current folder, `~`, `..`, `-` (previous folder) or use
/// `$VARIABLES`; names complete inline as you type (→, Tab or / accepts, Esc dismisses), Tab
/// completes the common part and then cycles through matches, ⌥⌫ or ⌃W deletes a path component, ⌃U clears,
/// and pasted quoted, escaped or `file://` paths are cleaned up. Paths resolve on the SSH host
/// when the active pane is remote, and `host:/path` opens a folder on any SSH host.
final class GoToFolderController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
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
    private let fieldEditor: GoToFieldEditor = {
        let editor = GoToFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()
    private let iconView = NSImageView()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var tableHeight: NSLayoutConstraint!
    private var suggestions: [Suggestion] = []
    private var remoteCache: [ItemRef: [FileItem]] = [:]
    private var pendingRemote = Set<ItemRef>()

    private var typed = ""                  // what the user typed, without an inline completion
    private var inline: Suggestion?         // completion shown selected after the caret
    private var lastEditInserted = false
    private var lastEditPasted = false
    private var cycling = false             // Tab is stepping through the matches

    private static let width: CGFloat = 520
    private static let rowHeight: CGFloat = 26
    private static let maxRows = 9

    static func present(on window: NSWindow, pane: PaneViewController, completion: @escaping (Location, ItemRef?) -> Void) {
        let controller = GoToFolderController(pane: pane, completion: completion)
        current = controller
        window.beginSheet(controller.window!) { _ in current = nil }
        controller.window?.makeFirstResponder(controller.field)
        controller.setText(controller.initialText)
        controller.field.currentEditor()?.selectAll(nil)
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
        panel.delegate = self
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
        fieldEditor.onEdit = { [weak self] range, string in self?.willEdit(range, string) ?? true }
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

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? GoToField) === field ? fieldEditor : nil
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

    /// The current folder’s absolute path, which the field starts with.
    private var initialText: String {
        switch pane.location.ref {
        case .local(let url)?: return url.path == "/" ? "/" : url.path + "/"
        case .remote(_, let path)?: return path.isEmpty ? "~/" : (path.hasSuffix("/") ? path : path + "/")
        default: return ""
        }
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
        var path = (expandVariables(input) as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            let base = pane.location.ref?.localURL?.path ?? Location.home.path
            path = (base as NSString).appendingPathComponent(path)
        }
        return .local(URL(fileURLWithPath: path).standardizedFileURL)
    }

    private func expandRemote(_ input: String, home: String, base: String) -> String {
        var path: String
        if input == "~" { path = home }
        else if input.hasPrefix("~/") { path = home + input.dropFirst(1) }
        else if input.hasPrefix("/") { path = input }
        else { path = (base as NSString).appendingPathComponent(input) }
        guard path.hasPrefix("/") else { return path }
        // Resolve . and .. the way a shell would.
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Expands `$NAME` and `${NAME}` from the environment, leaving unknown names alone.
    private func expandVariables(_ input: String) -> String {
        guard input.contains("$") else { return input }
        let regex = try! NSRegularExpression(pattern: #"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"#)
        let env = ProcessInfo.processInfo.environment
        let result = NSMutableString(string: input)
        for match in regex.matches(in: input, range: NSRange(location: 0, length: result.length)).reversed() {
            let name = (input as NSString).substring(with: match.range(at: 1))
            if let value = env[name] { result.replaceCharacters(in: match.range, with: value) }
        }
        return result as String
    }

    /// `~`, `.`, `..` and paths ending in them mean “inside that folder” when listing completions.
    private func isFolderShorthand(_ input: String) -> Bool {
        ["~", ".", ".."].contains(input) || input.hasSuffix("/.") || input.hasSuffix("/..")
            || (explicitHost(input).map { $0.path.isEmpty || $0.path == "~" } ?? false)
    }

    /// Cleans up a pasted path: quotes, backslash escapes, file:// URLs and stray whitespace.
    private func cleanedUpPaste(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("file://"), let url = URL(string: s), url.isFileURL {
            s = url.path + (s.hasSuffix("/") && url.path != "/" ? "/" : "")
        }
        if s.count >= 2, let quote = s.first, quote == "'" || quote == "\"", s.last == quote {
            s = String(s.dropFirst().dropLast())
        } else if s.contains("\\") {
            s = s.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        }
        return s
    }

    // MARK: Suggestions

    /// Recomputes the suggestions for what the user typed. With `autocomplete`, the best match
    /// is completed inline after the caret, like a browser’s address bar.
    private func refresh(autocomplete: Bool = false) {
        let input = typed
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

        if input == "-" {
            suggestions = pane.previousLocation?.ref.map { ref in
                [Suggestion(display: "-", ref: ref, isDirectory: true, icon: icon(for: ref, isDirectory: true))]
            } ?? []
            reloadTable(selectFirst: false)
            return
        }

        let listing = isFolderShorthand(input) ? input + "/" : input
        guard let resolved = resolve(listing) else { suggestions = []; reloadTable(selectFirst: false); return }
        let endsWithSlash = listing.hasSuffix("/")
        let directory = endsWithSlash ? resolved : (resolved.parent ?? resolved)
        let prefix = endsWithSlash ? "" : (listing as NSString).lastPathComponent
        let showHidden = Prefs.shared.showHidden || prefix.hasPrefix(".")
        // Completions keep exactly what was typed before the name, like a shell (~/, ../, $HOME/, host:).
        let typedFolder: String
        if let slash = listing.lastIndex(of: "/") {
            typedFolder = String(listing[...slash])
        } else if let (host, _) = explicitHost(listing) {
            typedFolder = "\(host):"
        } else {
            typedFolder = ""
        }

        let finish: ([FileItem]) -> Void = { [weak self] items in
            guard let self, self.typed == input else { return }
            var matches = items.filter { item in
                !FileService.alwaysHidden.contains(item.name) && (showHidden || !item.isHidden) && (prefix.isEmpty || item.name.lowercased().hasPrefix(prefix.lowercased()))
            }
            matches.sort { a, b in
                if a.isBrowsable != b.isBrowsable { return a.isBrowsable }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            var list = matches.prefix(60).map { item in
                Suggestion(display: typedFolder + item.name + (item.isBrowsable ? "/" : ""),
                           ref: item.ref, isDirectory: item.isBrowsable, icon: item.icon)
            }
            let best = list.first
            // Bare words also match recent locations, like Finder.
            if !input.contains("/") && self.explicitHost(input) == nil {
                for entry in GoToFolderController.history where (entry as NSString).lastPathComponent.lowercased().hasPrefix(input.lowercased()) {
                    guard let ref = self.historyRef(entry), !list.contains(where: { $0.ref == ref }) else { continue }
                    list.append(Suggestion(display: entry, ref: ref, isDirectory: true, icon: self.icon(for: ref, isDirectory: true)))
                }
            }
            self.suggestions = list
            self.reloadTable(selectFirst: false)
            if autocomplete, !prefix.isEmpty, let best, best.display.count > input.count,
               best.display.lowercased().hasPrefix(input.lowercased()) {
                self.showInline(best)
            }
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
                    if self.typed == input { self.refresh(autocomplete: autocomplete) }
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
        // The folder part is dimmed so the names stand out.
        let folderLength = text.lastIndex(where: { $0 == "/" || $0 == ":" }).map { text[...$0].utf16.count } ?? 0
        let attributed = NSMutableAttributedString(string: text, attributes: [.foregroundColor: NSColor.labelColor])
        attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: folderLength))
        cell.textField?.attributedStringValue = attributed
        return cell
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        // Clicking puts the path into the field so you can keep typing.
        setText(suggestions[row].display)
        moveCaretToEnd()
        refresh()
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        go(to: suggestions[row])
    }

    // MARK: Keys

    /// Called before every edit in the field.
    private func willEdit(_ range: NSRange, _ string: String?) -> Bool {
        let text = string ?? ""
        // Typing / over an inline folder completion accepts it instead of replacing it.
        if text == "/", let inline, inline.display.hasSuffix("/"), range == inlineRange {
            acceptInline()
            return false
        }
        lastEditInserted = !text.isEmpty
        lastEditPasted = text.count > 1
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        if lastEditPasted {
            let cleaned = cleanedUpPaste(field.stringValue)
            if cleaned != field.stringValue {
                field.stringValue = cleaned
                moveCaretToEnd()
            }
        }
        typed = field.stringValue
        inline = nil
        cycling = false
        let caretAtEnd = field.currentEditor()?.selectedRange == NSRange(location: (typed as NSString).length, length: 0)
        refresh(autocomplete: lastEditInserted && caretAtEnd)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1); return true
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToEndOfDocument(_:)):
            guard inline != nil else { return false }
            acceptInline(); return true
        case #selector(NSResponder.insertTab(_:)):
            if inline != nil { acceptInline() } else { complete() }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            cycle(by: -1); return true
        case #selector(NSResponder.deleteWordBackward(_:)):
            return deletePathComponent()
        case #selector(NSResponder.insertNewline(_:)):
            commit(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if inline != nil { dismissInline() } else { close() }
            return true
        default:
            return false
        }
    }

    /// Puts text in the field as if the user had typed it.
    private func setText(_ text: String) {
        field.stringValue = text
        typed = text
        inline = nil
        cycling = false
    }

    private var inlineRange: NSRange? {
        guard let inline else { return nil }
        let start = (typed as NSString).length
        return NSRange(location: start, length: (inline.display as NSString).length - start)
    }

    private func showInline(_ suggestion: Suggestion) {
        field.stringValue = suggestion.display
        inline = suggestion
        if let range = inlineRange { field.currentEditor()?.selectedRange = range }
    }

    private func acceptInline() {
        guard let inline else { return }
        setText(inline.display)
        moveCaretToEnd()
        refresh()
    }

    private func dismissInline() {
        field.stringValue = typed
        inline = nil
        moveCaretToEnd()
    }

    /// ⌥⌫ / ⌃W: deletes back to the previous path component, like a shell.
    private func deletePathComponent() -> Bool {
        guard let editor = field.currentEditor() else { return false }
        if inline == nil {
            let selection = editor.selectedRange
            guard selection.length == 0, selection.location == (typed as NSString).length else { return false }
        }
        var text = typed
        guard !text.isEmpty, text != "/" else { NSSound.beep(); return true }
        if text.hasSuffix("/") { text.removeLast() }
        if let slash = text.lastIndex(of: "/") { text = String(text[...slash]) } else { text = "" }
        setText(text)
        moveCaretToEnd()
        refresh()
        return true
    }

    private func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { NSSound.beep(); return }
        let current = table.selectedRow
        let next = current < 0 ? (delta > 0 ? 0 : suggestions.count - 1) : max(0, min(suggestions.count - 1, current + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    /// Tab, like a shell: completes a single match, otherwise the part all matches share;
    /// when nothing more is shared, repeated Tabs step through the matches (⇧Tab goes back).
    private func complete() {
        guard !suggestions.isEmpty else { NSSound.beep(); return }
        if cycling { cycle(by: 1); return }
        if table.selectedRow >= 0 {
            setText(suggestions[table.selectedRow].display)
        } else if suggestions.count == 1 {
            setText(suggestions[0].display)
        } else {
            let names = suggestions.map(\.display)
            let common = names.dropFirst().reduce(names[0]) { prefix, name in
                String(zip(prefix, name).prefix { $0.lowercased() == $1.lowercased() }.map(\.0))
            }
            guard common.count > typed.count else { cycle(by: 1); return }
            setText(common)
        }
        moveCaretToEnd()
        refresh()
    }

    /// Shows the next (or previous) match in the field while keeping the list of matches.
    private func cycle(by delta: Int) {
        guard !suggestions.isEmpty else { NSSound.beep(); return }
        let row = cycling && table.selectedRow >= 0
            ? (table.selectedRow + delta + suggestions.count) % suggestions.count
            : (delta > 0 ? 0 : suggestions.count - 1)
        cycling = true
        inline = nil
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        field.stringValue = suggestions[row].display
        moveCaretToEnd()
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
        if input == "-" {
            guard let previous = pane.previousLocation else { shake(); return }
            close()
            completion(previous, nil)
            return
        }
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
        controller.setText(text)
        controller.moveCaretToEnd()
        controller.refresh(autocomplete: true)
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

/// The path field’s editor, which reports edits before they happen.
final class GoToFieldEditor: NSTextView {
    var onEdit: ((NSRange, String?) -> Bool)?

    override func shouldChangeText(in range: NSRange, replacementString string: String?) -> Bool {
        guard onEdit?(range, string) ?? true else { return false }
        return super.shouldChangeText(in: range, replacementString: string)
    }

    /// Shell keys macOS doesn’t bind: ⌃W deletes a path component, ⌃U clears to the start.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": doCommand(by: #selector(NSResponder.deleteWordBackward(_:))); return
            case "u": doCommand(by: #selector(NSResponder.deleteToBeginningOfLine(_:))); return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

/// The path field. ⌘L (or ⇧⌘G) selects the whole path again.
final class GoToField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if (modifiers == .command && key == "l") || (modifiers == [.command, .shift] && key == "g") {
            currentEditor()?.selectAll(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
