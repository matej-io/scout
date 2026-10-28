import AppKit

/// Something a pane can show.
enum Location: Hashable {
    case folder(ItemRef)
    case recents
    case airdrop
    case network
    case computer
    case tag(String)

    var ref: ItemRef? {
        if case .folder(let ref) = self { return ref }
        return nil
    }

    var isRemote: Bool { ref?.isRemote ?? false }

    /// Whether files can be created or dropped here.
    var isWritableFolder: Bool { ref != nil }

    var title: String {
        switch self {
        case .folder(let ref):
            switch ref {
            case .local(let url):
                if url.path == "/" { return Location.volumeName(url) }
                if url == Location.trashURL { return Prefs.trashTitle }
                if url == Location.iCloudURL { return "iCloud Drive" }
                return FileManager.default.displayName(atPath: url.path)
            case .remote(let host, let path):
                let h = SSHManager.shared.host(host)
                if path.isEmpty || path == "/" { return h.displayName }
                return (path as NSString).lastPathComponent
            }
        case .recents: return "Recents"
        case .airdrop: return "AirDrop"
        case .network: return "Network"
        case .computer: return Host.current().localizedName ?? "Computer"
        case .tag(let name): return name
        }
    }

    var settingsRef: ItemRef {
        switch self {
        case .folder(let ref): return ref
        case .recents: return .local(URL(fileURLWithPath: "/.scout/recents"))
        case .airdrop: return .local(URL(fileURLWithPath: "/.scout/airdrop"))
        case .network: return .local(URL(fileURLWithPath: "/.scout/network"))
        case .computer: return .local(URL(fileURLWithPath: "/.scout/computer"))
        case .tag(let name): return .local(URL(fileURLWithPath: "/.scout/tag/\(name)"))
        }
    }

    var parent: Location? {
        switch self {
        case .folder(let ref):
            if case .local(let url) = ref, url.path == "/" { return .computer }
            if case .remote(let host, let path) = ref, path == "/" || path.isEmpty {
                _ = host
                return .network
            }
            return ref.parent.map { .folder($0) }
        default:
            return nil
        }
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var trashURL: URL { home.appendingPathComponent(".Trash") }
    static var iCloudURL: URL { home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs") }

    static func volumeName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
    }

    static func sidebarIcon(_ name: String) -> NSImage? {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(name).icns")
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }
}
