import AppKit

/// Scout's settings file, `~/.config/io.matej.Scout/config.json5`: a JSON5 object, so it can have
/// comments, single-quoted strings, trailing commas and unquoted keys.
/// The file is read at launch and again whenever it has changed when Scout comes to the front
/// (or on Reload Configuration). Its values win over menu toggles such as Show Hidden Files and over
/// favourites dragged into the sidebar, which last until the next reload.
final class Config {
    static let shared = Config()

    enum Kind {
        case bool
        case choice([String])
        case text
        case paths
    }

    static let keys: [String: Kind] = [
        "showHiddenFiles": .bool,
        "foldersFirst": .bool,
        "showPathBar": .bool,
        "showStatusBar": .bool,
        "showTags": .bool,
        "showRecents": .bool,
        "favorites": .paths,
        "defaultView": .choice(["icon", "list", "column", "gallery"]),
        "searchScope": .choice(["thisMac", "currentFolder", "previous"]),
        "autoUpdate": .bool,
        "terminal": .text,
        "terminalCommand": .text,
    ]

    static var directory: URL {
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let base = xdg.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("io.matej.Scout")
    }

    static var url: URL { directory.appendingPathComponent("config.json5") }

    private(set) var values: [String: Any] = [:]
    private var loadedDate: Date?

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reloadIfChanged()
        }
    }

    func string(_ key: String) -> String? { values[key] as? String }

    func bool(_ key: String) -> Bool? { values[key] as? Bool }

    func strings(_ key: String) -> [String]? { values[key] as? [String] }

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
        // A file that doesn't parse at all keeps the settings Scout already has.
        if let parsed { values = parsed }
        Prefs.shared.apply(self)
        if let auto = bool("autoUpdate") { Updater.shared.automaticallyChecks = auto }
        if !problems.isEmpty {
            Config.alert(parsed == nil ? "Scout couldn’t read the configuration." : "Some settings in the configuration were ignored.",
                         problems.joined(separator: "\n"))
        }
    }

    /// Parses the JSON5 text into checked values; `values` is nil when the text isn't a JSON5 object.
    static func parse(_ text: String) -> (values: [String: Any]?, problems: [String]) {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed])
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            return (nil, [detail])
        }
        guard let dictionary = object as? [String: Any] else {
            return (nil, ["The file should hold one object, between { and }."])
        }
        var values: [String: Any] = [:]
        var problems: [String] = []
        for (key, value) in dictionary.sorted(by: { $0.key < $1.key }) {
            guard let kind = keys[key] else { problems.append("Unknown setting “\(key)”"); continue }
            // null resets the setting to its default.
            if value is NSNull { continue }
            switch kind {
            case .bool:
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    problems.append("\(key) must be true or false"); continue
                }
                values[key] = number.boolValue
            case .choice(let options):
                guard let choice = value as? String, options.contains(choice) else {
                    problems.append("\(key) must be one of \(options.map { "\"\($0)\"" }.joined(separator: ", "))"); continue
                }
                values[key] = choice
            case .text:
                guard let string = value as? String else { problems.append("\(key) must be a string"); continue }
                if !string.isEmpty { values[key] = string }
            case .paths:
                guard let paths = value as? [Any], paths.allSatisfy({ $0 is String }) else {
                    problems.append("\(key) must be a list of paths, like [\"~/Documents\", \"/Applications\"]"); continue
                }
                values[key] = (paths as! [String]).map { ($0 as NSString).expandingTildeInPath }
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
    // Scout configuration (JSON5: comments, unquoted keys, single quotes and trailing commas are fine)
    //
    // Scout rereads this file when you switch back to it, or with Scout › Reload Configuration (⇧⌘,).
    // Uncomment a line to change a setting; leaving it out (or setting it to null) keeps the default.
    {
      // Finder-style options. The defaults follow your Finder settings, and the
      // View menu toggles still work until this file is next reloaded.
      // showHiddenFiles: false,
      // foldersFirst: false,
      // showPathBar: false,
      // showStatusBar: true,
      // showTags: true,
      // showRecents: true,

      // The folders under Favourites in the sidebar, in order. ~ is your home folder.
      // When set, this list replaces the sidebar's on every reload; folders dragged
      // in or out of the sidebar last until then.
      // favorites: ["/Applications", "~/Desktop", "~/Documents", "~/Downloads"],

      // How folders open until you pick a view for them: "icon", "list", "column" or "gallery".
      // Each folder remembers the view you last used in it.
      // defaultView: "list",

      // Where a new search looks: "thisMac", "currentFolder" or "previous".
      // searchScope: "thisMac",

      // Check for Scout updates automatically.
      // autoUpdate: true,

      // Open in Terminal
      //
      // terminal picks the app: "terminal" (the default), "iterm", "ghostty", "warp", "kitty",
      // "wezterm", "alacritty" or "cmux". Any other value is used as an app name, which
      // works for local folders only.
      // terminal: "ghostty",
      //
      // terminalCommand replaces that with your own command, run by your login shell
      // with these variables set:
      //   SCOUT_DIR      the local folder (empty for SSH folders)
      //   SCOUT_HOST     the SSH host (empty for local folders)
      //   SCOUT_PATH     the folder’s path, on the Mac or on the host
      //   SCOUT_COMMAND  a shell command that starts a shell in the folder (via ssh for SSH folders)
      // terminalCommand: "open -a Ghostty \\"$SCOUT_DIR\\"",
      // terminalCommand: "~/.config/io.matej.Scout/open-terminal.sh",
    }

    """
}
