import AppKit

enum ViewMode: Int, CaseIterable {
    case icon, list, column, gallery

    var title: String {
        switch self {
        case .icon: return "as Icons"
        case .list: return "as List"
        case .column: return "as Columns"
        case .gallery: return "as Gallery"
        }
    }

    var symbol: String {
        switch self {
        case .icon: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .column: return "rectangle.split.3x1"
        case .gallery: return "rectangle.bottomhalf.inset.filled"
        }
    }

    init?(finderStyle: String) {
        switch finderStyle {
        case "icnv": self = .icon
        case "Nlsv": self = .list
        case "clmv": self = .column
        case "glyv", "Flwv": self = .gallery
        default: return nil
        }
    }
}

enum SortKey: String, CaseIterable {
    case none, name, kind, application, lastOpened, added, modified, created, size, tags

    var title: String {
        switch self {
        case .none: return "None"
        case .name: return "Name"
        case .kind: return "Kind"
        case .application: return "Application"
        case .lastOpened: return "Date Last Opened"
        case .added: return "Date Added"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .size: return "Size"
        case .tags: return "Tags"
        }
    }

    static let menuOrder: [SortKey] = [.name, .kind, .lastOpened, .added, .modified, .created, .size, .tags]
}

/// App preferences. Initial values mirror the user's Finder settings.
final class Prefs {
    static let shared = Prefs()
    private let defaults = UserDefaults.standard
    private let finder = UserDefaults(suiteName: "com.apple.finder")

    static let changed = Notification.Name("ScoutPrefsChanged")

    private init() {
        var initial: [String: Any] = [
            "showHidden": finder?.bool(forKey: "AppleShowAllFiles") ?? false,
            "showStatusBar": finder?.object(forKey: "ShowStatusBar") as? Bool ?? true,
            "showPathBar": finder?.object(forKey: "ShowPathbar") as? Bool ?? false,
            "showTags": finder?.object(forKey: "ShowRecentTags") as? Bool ?? true,
            "iconSize": 64.0,
            "defaultViewMode": ViewMode.icon.rawValue,
            "foldersFirst": finder?.bool(forKey: "_FXSortFoldersFirst") ?? false,
            "searchScopeDefault": finder?.string(forKey: "FXDefaultSearchScope") ?? "SCev",
            "searchContents": true,
        ]
        if let style = finder?.string(forKey: "FXPreferredViewStyle"), let mode = ViewMode(finderStyle: style) {
            initial["defaultViewMode"] = mode.rawValue
        }
        defaults.register(defaults: initial)
    }

    private func post() { NotificationCenter.default.post(name: Prefs.changed, object: nil) }

    /// Takes the values set in the config file, leaving the rest as they are.
    func apply(_ config: Config) {
        let bools = ["show-hidden-files": "showHidden", "folders-first": "foldersFirst", "show-path-bar": "showPathBar",
                     "show-status-bar": "showStatusBar", "show-tags": "showTags", "show-recents": "showRecents"]
        for (key, pref) in bools {
            if let value = config.bool(key) { defaults.set(value, forKey: pref) }
        }
        if let scope = config.string("search-scope") {
            searchScopeDefault = ["this-mac": "SCev", "current-folder": "SCcf", "previous": "SCsp"][scope] ?? "SCev"
        }
        post()
    }

    var showHidden: Bool {
        get { defaults.bool(forKey: "showHidden") }
        set { defaults.set(newValue, forKey: "showHidden"); post() }
    }

    var showStatusBar: Bool {
        get { defaults.bool(forKey: "showStatusBar") }
        set { defaults.set(newValue, forKey: "showStatusBar"); post() }
    }

    var showPathBar: Bool {
        get { defaults.bool(forKey: "showPathBar") }
        set { defaults.set(newValue, forKey: "showPathBar"); post() }
    }

    var showTags: Bool {
        get { defaults.bool(forKey: "showTags") }
        set { defaults.set(newValue, forKey: "showTags"); post() }
    }

    var foldersFirst: Bool {
        get { defaults.bool(forKey: "foldersFirst") }
        set { defaults.set(newValue, forKey: "foldersFirst"); post() }
    }

    /// Finder’s “When performing a search” setting: SCev (This Mac), SCcf (current folder)
    /// or SCsp (the previous scope).
    var searchScopeDefault: String {
        get { defaults.string(forKey: "searchScopeDefault") ?? "SCev" }
        set { defaults.set(newValue, forKey: "searchScopeDefault") }
    }

    var lastSearchScope: SearchScope? {
        get { defaults.string(forKey: "lastSearchScope").flatMap(SearchScope.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: "lastSearchScope") }
    }

    /// Match names and contents (Finder’s default) rather than names only.
    var searchContents: Bool {
        get { defaults.bool(forKey: "searchContents") }
        set { defaults.set(newValue, forKey: "searchContents") }
    }

    var iconSize: CGFloat {
        get { CGFloat(defaults.double(forKey: "iconSize")) }
        set { defaults.set(Double(newValue), forKey: "iconSize") }
    }

    var defaultViewMode: ViewMode {
        ViewMode(rawValue: defaults.integer(forKey: "defaultViewMode")) ?? .icon
    }

    func viewMode(for ref: ItemRef) -> ViewMode {
        let modes = defaults.dictionary(forKey: "viewModes") as? [String: Int] ?? [:]
        if let raw = modes[ref.settingsKey], let mode = ViewMode(rawValue: raw) { return mode }
        return defaultViewMode
    }

    func setViewMode(_ mode: ViewMode, for ref: ItemRef) {
        var modes = defaults.dictionary(forKey: "viewModes") as? [String: Int] ?? [:]
        modes[ref.settingsKey] = mode.rawValue
        defaults.set(modes, forKey: "viewModes")
    }

    func sort(for ref: ItemRef) -> (key: SortKey, ascending: Bool) {
        let sorts = defaults.dictionary(forKey: "sorts") as? [String: String] ?? [:]
        if let value = sorts[ref.settingsKey] {
            let parts = value.split(separator: ":")
            if parts.count == 2, let key = SortKey(rawValue: String(parts[0])) {
                return (key, parts[1] == "a")
            }
        }
        return (.name, true)
    }

    func setSort(_ key: SortKey, ascending: Bool, for ref: ItemRef) {
        var sorts = defaults.dictionary(forKey: "sorts") as? [String: String] ?? [:]
        sorts[ref.settingsKey] = "\(key.rawValue):\(ascending ? "a" : "d")"
        defaults.set(sorts, forKey: "sorts")
    }

    /// Sidebar favourites as file paths.
    var favorites: [String] {
        get {
            if let stored = defaults.stringArray(forKey: "favorites") { return stored }
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            return ["/Applications",
                    home.appendingPathComponent("Desktop").path,
                    home.appendingPathComponent("Documents").path,
                    home.appendingPathComponent("Downloads").path]
        }
        set { defaults.set(newValue, forKey: "favorites"); post() }
    }

    var showRecents: Bool {
        get { defaults.object(forKey: "showRecents") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showRecents"); post() }
    }

    /// SSH destinations added through Connect to Server.
    var customHosts: [String] {
        get { defaults.stringArray(forKey: "customHosts") ?? [] }
        set { defaults.set(newValue, forKey: "customHosts"); post() }
    }

    var hiddenHosts: [String] {
        get { defaults.stringArray(forKey: "hiddenHosts") ?? [] }
        set { defaults.set(newValue, forKey: "hiddenHosts"); post() }
    }

    var recentServers: [String] {
        get { defaults.stringArray(forKey: "recentServers") ?? [] }
        set { defaults.set(Array(newValue.prefix(10)), forKey: "recentServers") }
    }

    /// Uses British wording ("Favourites", "Bin") like Finder does for those locales.
    static var usesBritishWording: Bool {
        let id = Locale.current.identifier
        return !(id.hasPrefix("en_US") || id == "en")
    }

    static var favoritesTitle: String { usesBritishWording ? "Favourites" : "Favorites" }
    static var trashTitle: String { usesBritishWording ? "Bin" : "Trash" }
}
