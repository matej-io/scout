import Foundation

/// Where a search looks, like Finder’s scope bar.
enum SearchScope: String {
    case thisMac        // every local volume (Spotlight)
    case disk           // the volume holding the current folder
    case folder         // the current folder and everything below it
    case server         // the whole SSH host (from /)
}

protocol SearchHandle: AnyObject {
    func cancel()
}

/// A running search. `update` is called with results as they arrive; `finished` is true once
/// the initial pass is done (Spotlight searches keep updating live after that).
typealias SearchUpdate = (Result<[FileItem], Error>, _ finished: Bool) -> Void

extension FileService {
    static func search(_ text: String, scope: SearchScope, in location: Location, contents: Bool, showHidden: Bool,
                       update: @escaping SearchUpdate) -> SearchHandle? {
        switch location {
        case .folder(.remote(let host, let path)):
            return RemoteSearch(text, host: host, path: scope == .server ? "/" : path, contents: contents,
                                showHidden: showHidden, update: update)
        case .folder(.local(let url)):
            let scopes: [Any]
            switch scope {
            case .folder: scopes = [url]
            case .disk: scopes = [volume(of: url)?.url ?? url]
            case .thisMac, .server: scopes = [NSMetadataQueryLocalComputerScope]
            }
            return SpotlightSearch(text, scopes: scopes, contents: contents, showHidden: showHidden, update: update)
        default:
            return SpotlightSearch(text, scopes: [NSMetadataQueryLocalComputerScope], contents: contents,
                                   showHidden: showHidden, update: update)
        }
    }

    /// The volume a local folder is on, with its name.
    static func volume(of url: URL) -> (url: URL, name: String)? {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeLocalizedNameKey]),
              let volume = values.volume else { return nil }
        return (volume, values.volumeLocalizedName ?? volume.lastPathComponent)
    }
}

/// A live Spotlight search (NSMetadataQuery), which is what Finder uses.
final class SpotlightSearch: NSObject, SearchHandle {
    private static let limit = 5000

    private let query = NSMetadataQuery()
    private let showHidden: Bool
    private let update: SearchUpdate
    private let queue = DispatchQueue(label: "io.matej.Scout.search", qos: .userInitiated)
    private var cache: [String: FileItem] = [:]   // only touched on `queue`
    private var generation = 0
    private var finished = false
    private var cancelled = false

    init?(_ text: String, scopes: [Any], contents: Bool, showHidden: Bool, update: @escaping SearchUpdate) {
        guard let predicate = NSPredicate(fromMetadataQueryString: SpotlightSearch.queryString(text, contents: contents)) else { return nil }
        self.showHidden = showHidden
        self.update = update
        super.init()
        query.predicate = predicate
        query.searchScopes = scopes
        query.notificationBatchingInterval = 0.25
        let nc = NotificationCenter.default
        for name in [NSNotification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            nc.addObserver(self, selector: #selector(changed(_:)), name: name, object: query)
        }
        query.start()
    }

    /// Finder’s default search matches words in any attribute (name, contents, metadata);
    /// “Name Only” matches part of the file name. Names also match anywhere, which suits code.
    static func queryString(_ text: String, contents: Bool) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "*", with: "\\*")
        }
        let name = { (s: String) in "(kMDItemFSName == \"*\(escape(s))*\"cd || kMDItemDisplayName == \"*\(escape(s))*\"cd)" }
        guard contents else { return name(text) }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let clauses = words.map { "(** == \"\(escape($0))*\"cdw || \(name($0)))" }
        return clauses.isEmpty ? name(text) : clauses.joined(separator: " && ")
    }

    @objc private func changed(_ notification: Notification) {
        if notification.name == .NSMetadataQueryDidFinishGathering { finished = true }
        deliver()
    }

    private func deliver() {
        guard !cancelled else { return }
        query.disableUpdates()
        var paths: [String] = []
        let count = min(query.resultCount, SpotlightSearch.limit)
        paths.reserveCapacity(count)
        for i in 0..<count {
            if let item = query.result(at: i) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                paths.append(path)
            }
        }
        query.enableUpdates()

        generation += 1
        let generation = self.generation
        let finished = self.finished
        let showHidden = self.showHidden
        queue.async { [weak self] in
            guard let self else { return }
            var items: [FileItem] = []
            for path in paths {
                if !showHidden && path.contains("/.") { continue }
                if let cached = self.cache[path] { items.append(cached); continue }
                guard let item = FileItem.local(URL(fileURLWithPath: path)) else { continue }
                self.cache[path] = item
                items.append(item)
            }
            if !showHidden { items.removeAll { $0.isHidden || FileService.alwaysHidden.contains($0.name) } }
            DispatchQueue.main.async {
                guard !self.cancelled, generation == self.generation else { return }
                self.update(.success(items), finished)
            }
        }
    }

    func cancel() {
        cancelled = true
        query.stop()
        NotificationCenter.default.removeObserver(self)
    }
}

/// Searches an SSH host with find (names) and grep (contents), limited in time and results.
final class RemoteSearch: SearchHandle {
    private var cancelled = false

    init(_ text: String, host: String, path: String, contents: Bool, showHidden: Bool, update: @escaping SearchUpdate) {
        let pattern = "*" + text.replacingOccurrences(of: "*", with: "\\*") + "*"
        let root = shq(path)
        // Hidden folders are skipped unless shown (or the search starts inside one).
        let skipHidden = !showHidden && !path.split(separator: "/").contains { $0.hasPrefix(".") }
        let prune = skipHidden ? "\\( -name '.*' -prune \\) -o " : ""
        var producers = ["timeout 30 find \(root) -xdev -mindepth 1 \(prune)-iname \(shq(pattern)) -print0 2>/dev/null"]
        if contents {
            var excludes = skipHidden ? " --exclude-dir='.*'" : ""
            if path == "/" { excludes += " --exclude-dir=proc --exclude-dir=sys --exclude-dir=dev --exclude-dir=run" }
            producers.append("timeout 30 grep -rlIisZ -F\(excludes) -- \(shq(text)) \(root) 2>/dev/null")
        }
        let format = "%y\\t%Y\\t%s\\t%T@\\t%p\\0"
        let command = "{ \(producers.joined(separator: "; ")); } | head -z -n 3000 | sort -zu"
            + " | xargs -0 -r sh -c 'exec find \"$@\" -maxdepth 0 -printf \"\(format)\"' sh; true"
        SSHManager.shared.host(host).list(path, command: command) { [weak self] result in
            guard let self, !self.cancelled else { return }
            update(result.map { items in showHidden ? items : items.filter { !$0.isHidden } }, true)
        }
    }

    func cancel() { cancelled = true }
}
