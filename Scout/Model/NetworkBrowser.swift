import AppKit
import Network
import UniformTypeIdentifiers

/// Fills the Network location: SSH hosts from ~/.ssh/config plus servers
/// advertised over Bonjour (SMB file sharing and SSH/SFTP).
final class NetworkBrowser {
    static let shared = NetworkBrowser()
    static let changed = Notification.Name("ScoutNetworkChanged")

    private var browsers: [NWBrowser] = []
    private var smb: Set<String> = []
    private var ssh: Set<String> = []

    static var serverIcon: NSImage {
        NSWorkspace.shared.icon(for: UTType("com.apple.file-server") ?? .folder)
    }

    func start() {
        guard browsers.isEmpty else { return }
        for type in ["_smb._tcp", "_sftp-ssh._tcp"] {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let names = Set(results.compactMap { result -> String? in
                    if case .service(let name, _, _, _) = result.endpoint { return name }
                    return nil
                })
                DispatchQueue.main.async {
                    if type == "_smb._tcp" { self?.smb = names } else { self?.ssh = names }
                    NotificationCenter.default.post(name: NetworkBrowser.changed, object: nil)
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    var items: [FileItem] {
        var items: [FileItem] = []
        var seen = Set<String>()
        for host in SSHManager.shared.hosts {
            seen.insert(host.destination.lowercased())
            let item = FileItem(ref: .remote(host: host.destination, path: ""), name: host.displayName, isDirectory: true,
                                isHidden: false, size: nil, modified: nil,
                                kind: host.entry.map { "SSH Server — \($0.subtitle)" } ?? "SSH Server")
            item.iconOverride = NetworkBrowser.serverIcon
            items.append(item)
        }
        for name in ssh.sorted() where !seen.contains(name.lowercased()) && !seen.contains("\(name.lowercased()).local") {
            let host = name.replacingOccurrences(of: " ", with: "-") + ".local"
            let item = FileItem(ref: .remote(host: host, path: ""), name: name, isDirectory: true, isHidden: false,
                                size: nil, modified: nil, kind: "SSH Server (Bonjour)")
            item.iconOverride = NetworkBrowser.serverIcon
            items.append(item)
        }
        for name in smb.sorted() {
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? name
            guard let url = URL(string: "smb://\(encoded)._smb._tcp.local") else { continue }
            let item = FileItem(ref: .local(url), name: name, isDirectory: true, isHidden: false, size: nil,
                                modified: nil, kind: "File Server")
            item.iconOverride = NetworkBrowser.serverIcon
            items.append(item)
        }
        return items
    }
}
