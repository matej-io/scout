import AppKit

enum FileService {
    /// Finder never shows these, even with hidden files visible.
    static let alwaysHidden: Set<String> = [".DS_Store", ".localized"]
    static let folderChanged = Notification.Name("ScoutFolderChanged")

    static func notifyChanged(_ folders: [ItemRef]) {
        NotificationCenter.default.post(name: folderChanged, object: nil, userInfo: ["folders": folders])
    }

    // MARK: Listing

    static func list(_ ref: ItemRef, showHidden: Bool, completion: @escaping (Result<[FileItem], Error>) -> Void) {
        switch ref {
        case .local(let url):
            DispatchQueue.global(qos: .userInitiated).async {
                let result = listLocal(url, showHidden: showHidden)
                DispatchQueue.main.async { completion(result) }
            }
        case .remote(let host, let path):
            SSHManager.shared.host(host).list(path) { result in
                completion(result.map { items in showHidden ? items.filter { !FileService.alwaysHidden.contains($0.name) } : items.filter { !$0.isHidden } })
            }
        }
    }

    static func listSync(_ ref: ItemRef, showHidden: Bool) -> Result<[FileItem], Error> {
        switch ref {
        case .local(let url):
            return listLocal(url, showHidden: showHidden)
        case .remote(let host, let path):
            return SSHManager.shared.host(host).listSync(path).map { items in
                showHidden ? items : items.filter { !$0.isHidden }
            }
        }
    }

    static func listLocal(_ url: URL, showHidden: Bool) -> Result<[FileItem], Error> {
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: FileItem.localKeys,
                                                                   options: showHidden ? [] : [.skipsHiddenFiles])
            var items = urls.filter { !FileService.alwaysHidden.contains($0.lastPathComponent) }.compactMap(FileItem.local)
            if url.path == "/" && !showHidden {
                items = items.filter { !$0.isHidden }
            }
            return .success(items)
        } catch {
            return .failure(error)
        }
    }

    static func list(_ location: Location, showHidden: Bool, completion: @escaping (Result<[FileItem], Error>) -> Void) {
        switch location {
        case .folder(let ref):
            list(ref, showHidden: showHidden, completion: completion)
        case .recents:
            spotlight("kMDItemLastUsedDate >= $time.today(-30) && kMDItemContentTypeTree != public.folder && kMDItemContentTypeTree != com.apple.application-bundle",
                      onlyIn: Location.home, limit: 400, completion: completion)
        case .tag(let name):
            spotlight("kMDItemUserTags == '\(name.replacingOccurrences(of: "'", with: "\\'"))'", onlyIn: nil, limit: 1000, completion: completion)
        case .computer:
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsBrowsableKey], options: [.skipHiddenVolumes]) ?? []
            var items = volumes.compactMap(FileItem.local)
            items.append(FileItem(ref: .local(URL(string: "scout:network")!), name: "Network", isDirectory: true,
                                  isHidden: false, size: nil, modified: nil, kind: "Network"))
            completion(.success(items))
        case .network:
            completion(.success(NetworkBrowser.shared.items))
        case .airdrop:
            completion(.success([]))
        }
    }

    static func search(_ query: String, in location: Location, showHidden: Bool, completion: @escaping (Result<[FileItem], Error>) -> Void) {
        switch location {
        case .folder(.remote(let host, let path)):
            let pattern = "*" + query.replacingOccurrences(of: "*", with: "\\*") + "*"
            let cmd = "find \(shq(path)) -mindepth 1 -iname \(shq(pattern)) -printf '%y\\t%Y\\t%s\\t%T@\\t%p\\0' 2>/dev/null | head -c 4000000"
            SSHManager.shared.host(host).list(path, command: cmd) { result in
                completion(result.map { items in showHidden ? items : items.filter { !$0.isHidden } })
            }
        case .folder(.local(let url)):
            spotlight(nil, name: query, onlyIn: url, limit: 2000, completion: completion)
        default:
            spotlight(nil, name: query, onlyIn: Location.home, limit: 2000, completion: completion)
        }
    }

    private static func spotlight(_ query: String?, name: String? = nil, onlyIn: URL?, limit: Int,
                                  completion: @escaping (Result<[FileItem], Error>) -> Void) {
        var args: [String] = []
        if let onlyIn { args += ["-onlyin", onlyIn.path] }
        if let name { args += ["-name", name] }
        if let query { args.append(query) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ProcessRunner.runSync("/usr/bin/mdfind", args)
            let paths = result.stdoutString.split(separator: "\n").prefix(limit)
            let items = paths.compactMap { FileItem.local(URL(fileURLWithPath: String($0))) }
            DispatchQueue.main.async { completion(.success(items)) }
        }
    }

    static func availableSpace(for location: Location, completion: @escaping (Int64?) -> Void) {
        switch location.ref {
        case .local(let url):
            DispatchQueue.global().async {
                let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
                let value = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
                DispatchQueue.main.async { completion(value) }
            }
        case .remote(let host, let path):
            SSHManager.shared.host(host).availableSpace(path, completion: completion)
        case nil:
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            completion(values?.volumeAvailableCapacityForImportantUsage)
        }
    }

    // MARK: Names

    static func uniqueName(_ name: String, existing: Set<String>, isDirectory: Bool, copySuffix: Bool = false) -> String {
        if !existing.contains(name) && !copySuffix { return name }
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        func make(_ suffix: String) -> String { ext.isEmpty ? base + suffix : base + suffix + "." + ext }
        if copySuffix {
            let first = make(" copy")
            if !existing.contains(first) { return first }
            var n = 2
            while existing.contains(make(" copy \(n)")) { n += 1 }
            return make(" copy \(n)")
        }
        var n = 2
        while existing.contains(make(" \(n)")) { n += 1 }
        return make(" \(n)")
    }

    static func existingNames(in folder: ItemRef) -> Set<String> {
        switch listSync(folder, showHidden: true) {
        case .success(let items): return Set(items.map(\.name))
        case .failure: return []
        }
    }
}

// MARK: - Directory watcher

final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    init?(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            self?.debounce?.cancel()
            let work = DispatchWorkItem(block: onChange)
            self?.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit {
        debounce?.cancel()
        source?.cancel()
    }
}

// MARK: - Activity (shown in the status bar)

final class Activity {
    static let shared = Activity()
    static let changed = Notification.Name("ScoutActivityChanged")

    private(set) var tasks: [UUID: String] = [:]
    private var order: [UUID] = []

    var current: String? { order.last.flatMap { tasks[$0] } }

    func begin(_ title: String) -> UUID {
        let id = UUID()
        tasks[id] = title
        order.append(id)
        NotificationCenter.default.post(name: Activity.changed, object: nil)
        return id
    }

    func end(_ id: UUID) {
        tasks[id] = nil
        order.removeAll { $0 == id }
        NotificationCenter.default.post(name: Activity.changed, object: nil)
    }
}
