import AppKit

/// Scout's settings file, `~/.config/io.matej.Scout/config`, written like Ghostty's: one `key = value`
/// per line, `#` starts a comment, and a later line wins over an earlier one.
/// The file is read at launch and again whenever it has changed when Scout comes to the front
/// (or on Reload Configuration). Its values win over menu toggles such as Show Hidden Files,
/// which last until the next reload.
final class Config {
    static let shared = Config()

    enum Kind {
        case bool
        case choice([String])
        case text
    }

    static let keys: [String: Kind] = [
        "show-hidden-files": .bool,
        "folders-first": .bool,
        "show-path-bar": .bool,
        "show-status-bar": .bool,
        "show-tags": .bool,
        "show-recents": .bool,
        "search-scope": .choice(["this-mac", "current-folder", "previous"]),
        "auto-update": .bool,
        "terminal": .text,
        "terminal-command": .text,
    ]

    static var url: URL {
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let base = xdg.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("io.matej.Scout/config")
    }

    private(set) var values: [String: String] = [:]
    private var loadedDate: Date?

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reloadIfChanged()
        }
    }

    func string(_ key: String) -> String? { values[key] }

    func bool(_ key: String) -> Bool? { values[key].map { $0 == "true" } }

    private static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func reloadIfChanged() {
        if Config.modificationDate() != loadedDate { reload() }
    }

    /// Reads the file and applies it. `reportMissing` is for the menu command, where silence would be confusing.
    func reload(reportMissing: Bool = false) {
        loadedDate = Config.modificationDate()
        guard let text = try? String(contentsOf: Config.url, encoding: .utf8) else {
            values = [:]
            if reportMissing { Config.alert("There’s no configuration file yet.", "Choose Scout › Settings… to create one at \(Config.displayPath).") }
            return
        }
        let (parsed, problems) = Config.parse(text)
        values = parsed
        Prefs.shared.apply(self)
        if let auto = bool("auto-update") { Updater.shared.automaticallyChecks = auto }
        if !problems.isEmpty {
            Config.alert("Some lines in the configuration were ignored.", problems.joined(separator: "\n"))
        }
    }

    static func parse(_ text: String) -> (values: [String: String], problems: [String]) {
        var values: [String: String] = [:]
        var problems: [String] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let at = "Line \(index + 1)"
            guard let eq = line.firstIndex(of: "=") else { problems.append("\(at): expected key = value"); continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            guard let kind = keys[key] else { problems.append("\(at): unknown key “\(key)”"); continue }
            switch kind {
            case .bool where value != "true" && value != "false":
                problems.append("\(at): \(key) must be true or false")
            case .choice(let options) where !options.contains(value):
                problems.append("\(at): \(key) must be one of \(options.joined(separator: ", "))")
            default:
                // An empty value resets the key to its default, as in Ghostty.
                if value.isEmpty { values[key] = nil } else { values[key] = value }
            }
        }
        return (values, problems)
    }

    static var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Opens the file in the default text editor, creating it from the template first.
    static func openInEditor() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try template.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                alert("Couldn’t create \(displayPath).", error.localizedDescription)
                return
            }
        }
        let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    static func alert(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }

    static let template = """
    # Scout configuration
    #
    # One `key = value` per line; lines starting with # are comments.
    # Scout rereads this file when you switch back to it, or with Scout › Reload Configuration (⇧⌘,).
    # Uncomment a line to change a setting; leaving it out keeps the default.

    # Finder-style options. The defaults follow your Finder settings, and the
    # View menu toggles still work until this file is next reloaded.
    # show-hidden-files = false
    # folders-first = false
    # show-path-bar = false
    # show-status-bar = true
    # show-tags = true
    # show-recents = true

    # Where a new search looks: this-mac, current-folder or previous
    # search-scope = this-mac

    # Check for Scout updates automatically.
    # auto-update = true

    # Open in Terminal
    #
    # terminal picks the app: terminal (the default), iterm, ghostty, warp, kitty,
    # wezterm, alacritty or cmux. Any other value is used as an app name, which
    # works for local folders only.
    # terminal = ghostty
    #
    # terminal-command replaces that with your own command, run by your login shell
    # with these variables set:
    #   SCOUT_DIR      the local folder (empty for SSH folders)
    #   SCOUT_HOST     the SSH host (empty for local folders)
    #   SCOUT_PATH     the folder’s path, on the Mac or on the host
    #   SCOUT_COMMAND  a shell command that starts a shell in the folder (via ssh for SSH folders)
    # terminal-command = open -a Ghostty "$SCOUT_DIR"
    # terminal-command = ~/.config/io.matej.Scout/open-terminal.sh

    """
}
