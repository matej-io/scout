import AppKit

/// The iCloud Drive (or other File Provider) state Finder shows next to an item's name.
enum CloudStatus: Equatable {
    /// Downloaded and up to date. Finder shows nothing.
    case current
    /// Only in iCloud ("In iCloud").
    case notDownloaded
    case downloading
    case waitingToUpload
    case uploading
    /// Not uploaded because iCloud storage is full.
    case outOfSpace
    /// Can't be stored in iCloud (for example, larger than the limit).
    case ineligible
    case downloadFailed

    static let keys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                         .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadRequestedKey,
                                         .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
                                         .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey]

    /// Nil when the item isn't in iCloud Drive or another cloud folder.
    init?(_ values: URLResourceValues, url: URL) {
        if CloudStatus.fakeEnabled { guard let fake = CloudStatus.fake(for: url) else { return nil }; self = fake; return }
        guard values.isUbiquitousItem == true else { return nil }
        if values.ubiquitousItemIsDownloading == true { self = .downloading; return }
        if values.ubiquitousItemIsUploading == true { self = .uploading; return }
        if let error = values.ubiquitousItemUploadingError {
            let full = error.domain == NSCocoaErrorDomain && error.code == CocoaError.ubiquitousFileNotUploadedDueToQuota.rawValue
            self = full ? .outOfSpace : .ineligible
            return
        }
        if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            if values.ubiquitousItemDownloadingError != nil { self = .downloadFailed; return }
            // A requested download that hasn't started moving yet already shows an empty pie in Finder.
            self = values.ubiquitousItemDownloadRequested == true ? .downloading : .notDownloaded
            return
        }
        if values.ubiquitousItemIsUploaded == false { self = .waitingToUpload; return }
        self = .current
    }

    /// Reads the item's state now, bypassing cached resource values.
    static func read(_ url: URL) -> CloudStatus? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: Set(keys)) else { return nil }
        return CloudStatus(values, url: url)
    }

    /// Something is moving, or about to: worth checking often.
    var isTransient: Bool { [.downloading, .uploading, .waitingToUpload].contains(self) }
    var isTransfer: Bool { self == .downloading || self == .uploading }
    /// Finder shows a badge for everything except up-to-date items.
    var showsBadge: Bool { self != .current }
    var canDownload: Bool { self == .notDownloaded || self == .downloadFailed }

    var symbolName: String? {
        switch self {
        case .notDownloaded: return "icloud.and.arrow.down"
        case .waitingToUpload: return "icloud.dashed"
        case .outOfSpace, .downloadFailed: return "exclamationmark.icloud"
        case .ineligible: return "icloud.slash"
        case .current, .downloading, .uploading: return nil
        }
    }

    func toolTip(fraction: Double?) -> String? {
        let percent = fraction.map { " – \(Int(($0 * 100).rounded()))%" } ?? ""
        switch self {
        case .current: return nil
        case .notDownloaded: return "In iCloud. Click to download."
        case .downloading: return "Downloading" + percent
        case .waitingToUpload: return "Waiting to upload"
        case .uploading: return "Uploading" + percent
        case .outOfSpace: return "Not uploaded: iCloud storage is full"
        case .ineligible: return "Can’t be stored in iCloud"
        case .downloadFailed: return "Couldn’t download. Click to try again."
        }
    }

    // MARK: Debug

    /// SCOUT_FAKE_CLOUD=1 gives every local item a made-up state (stable per name), for snapshots on a Mac without iCloud.
    static let fakeEnabled = ProcessInfo.processInfo.environment["SCOUT_FAKE_CLOUD"] == "1"

    private static func fake(for url: URL) -> CloudStatus? {
        let all: [CloudStatus?] = [nil, .current, .notDownloaded, .downloading, .waitingToUpload, .uploading,
                                   .outOfSpace, .ineligible, .notDownloaded]
        let hash = url.lastPathComponent.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return all[hash % all.count]
    }
}

/// Keeps the cloud state of the items on screen up to date, and the progress of their transfers.
///
/// Views register the items they show with `observe`. While any of them is moving the monitor checks them every
/// second (and every few seconds otherwise, to catch downloads started by other apps), and subscribes to the progress
/// the system publishes for the transfer. Changes are posted as `CloudMonitor.changed`, with the item's path as object.
final class CloudMonitor {
    static let shared = CloudMonitor()
    static let changed = Notification.Name("ScoutCloudStatusChanged")

    private struct Entry {
        var status: CloudStatus?
        var checked: Date
    }

    private final class Observer {
        weak var owner: AnyObject?
        var paths: Set<String> = []
        init(_ owner: AnyObject) { self.owner = owner }
    }

    private var entries: [String: Entry] = [:]
    private var fractions: [String: Double] = [:]
    private var subscriptions: [String: Any] = [:]
    private var observers: [ObjectIdentifier: Observer] = [:]
    private var timer: Timer?
    private var tick = 0
    private var polling = false
    private let queue = DispatchQueue(label: "io.matej.scout.cloud", qos: .utility)

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    // MARK: Reading

    /// The latest known state: the monitor's if it checked after the item was listed, else the listing's.
    func status(for item: FileItem) -> CloudStatus? {
        guard item.cloud != nil, let url = item.ref.localURL else { return item.cloud }
        if let entry = entries[CloudMonitor.key(url)], entry.checked > item.cloudChecked { return entry.status }
        return item.cloud
    }

    /// How far a download or upload has got, when the system reports it.
    func fraction(for item: FileItem) -> Double? {
        guard let url = item.ref.localURL else { return nil }
        if CloudStatus.fakeEnabled, status(for: item)?.isTransfer == true {
            return item.name.count % 2 == 0 ? 0.35 : 0.7
        }
        return fractions[CloudMonitor.key(url)]
    }

    // MARK: Observing

    /// Starts keeping `item` up to date for `owner` (held weakly). `replacing` drops what the owner watched before.
    func observe(_ item: FileItem, owner: AnyObject, replacing: Bool = true) {
        let id = ObjectIdentifier(owner)
        let observer = observers[id].flatMap { $0.owner === owner ? $0 : nil } ?? Observer(owner)
        observers[id] = observer
        if replacing { observer.paths = [] }
        guard item.cloud != nil, let url = item.ref.localURL else { return }
        let key = CloudMonitor.key(url)
        observer.paths.insert(key)
        if entries[key].map({ $0.checked < item.cloudChecked }) ?? true {
            entries[key] = Entry(status: item.cloud, checked: item.cloudChecked)
        }
        if item.cloud?.isTransfer == true { subscribe(key) }
        startTimer()
    }

    func stopObserving(owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
    }

    private var observedPaths: Set<String> {
        observers = observers.filter { $0.value.owner != nil }
        return observers.values.reduce(into: Set<String>()) { $0.formUnion($1.paths) }
    }

    private func startTimer() {
        guard timer == nil, !CloudStatus.fakeEnabled else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let paths = observedPaths
        // Forget transfers nobody shows any more.
        for key in subscriptions.keys where !paths.contains(key) { unsubscribe(key) }
        guard !paths.isEmpty else {
            timer?.invalidate()
            timer = nil
            entries = [:]
            fractions = [:]
            return
        }
        if entries.count > paths.count * 2 { entries = entries.filter { paths.contains($0.key) } }
        guard !polling else { return }
        tick += 1
        let everything = tick % 3 == 0
        let due = everything ? paths : paths.filter { entries[$0]?.status?.isTransient == true || subscriptions[$0] != nil }
        guard !due.isEmpty else { return }
        polling = true
        queue.async { [weak self] in
            let results = due.map { ($0, CloudStatus.read(URL(fileURLWithPath: $0))) }
            let now = Date()
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                for (key, status) in results { self.update(key, status, at: now) }
            }
        }
    }

    private func update(_ key: String, _ status: CloudStatus?, at date: Date) {
        let old = entries[key]?.status
        entries[key] = Entry(status: status, checked: date)
        if status?.isTransfer == true { subscribe(key) } else { unsubscribe(key) }
        if old != status { post(key) }
    }

    private func post(_ key: String) {
        NotificationCenter.default.post(name: CloudMonitor.changed, object: key)
    }

    // MARK: Progress

    /// Thread-safe holder for the last percentage reported, so progress updates are posted once per percent.
    private final class Throttle {
        private let lock = NSLock()
        private var last = -1
        func shouldReport(_ fraction: Double) -> Bool {
            let percent = Int(fraction * 100)
            lock.lock(); defer { lock.unlock() }
            guard percent != last else { return false }
            last = percent
            return true
        }
    }

    private func subscribe(_ key: String) {
        guard subscriptions[key] == nil, !CloudStatus.fakeEnabled else { return }
        let url = URL(fileURLWithPath: key)
        // The handlers run on other threads; the monitor is only touched back on the main thread.
        subscriptions[key] = Progress.addSubscriber(forFileURL: url) { progress in
            let throttle = Throttle()
            let report = { (progress: Progress) in
                let fraction = progress.fractionCompleted
                guard progress.totalUnitCount > 0, throttle.shouldReport(fraction) else { return }
                DispatchQueue.main.async { CloudMonitor.shared.setFraction(key, fraction) }
            }
            report(progress)
            let observation = progress.observe(\.fractionCompleted) { progress, _ in report(progress) }
            return {
                observation.invalidate()
                // The transfer is over: look at the item again straight away.
                DispatchQueue.main.async { CloudMonitor.shared.recheck(key) }
            }
        }
    }

    private func unsubscribe(_ key: String) {
        if let token = subscriptions.removeValue(forKey: key) { Progress.removeSubscriber(token) }
        if fractions.removeValue(forKey: key) != nil { post(key) }
    }

    private func setFraction(_ key: String, _ fraction: Double) {
        guard subscriptions[key] != nil else { return }
        fractions[key] = min(1, max(0, fraction))
        post(key)
    }

    private func recheck(_ key: String) {
        queue.async { [weak self] in
            let status = CloudStatus.read(URL(fileURLWithPath: key))
            let now = Date()
            DispatchQueue.main.async { self?.update(key, status, at: now) }
        }
    }

    // MARK: Actions

    /// Finder's Download Now. A folder downloads with everything in it.
    func download(_ urls: [URL], completion: ((Error?) -> Void)? = nil) {
        let now = Date()
        for url in urls {
            let key = CloudMonitor.key(url)
            entries[key] = Entry(status: .downloading, checked: now)
            subscribe(key)
            post(key)
        }
        startTimer()
        queue.async { [weak self] in
            var firstError: Error?
            for url in urls {
                do {
                    try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        CloudMonitor.downloadContents(of: url)
                    }
                } catch {
                    firstError = firstError ?? error
                }
            }
            DispatchQueue.main.async {
                for url in urls { self?.recheck(CloudMonitor.key(url)) }
                completion?(firstError)
            }
        }
    }

    private static func downloadContents(of folder: URL) {
        let keys = [URLResourceKey.ubiquitousItemDownloadingStatusKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: Set(keys)))?.ubiquitousItemDownloadingStatus == .notDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
    }

    /// Finder's Remove Download: keeps the item in iCloud and frees the space on this Mac.
    func removeDownload(_ urls: [URL], completion: @escaping (Error?) -> Void) {
        startTimer()
        queue.async { [weak self] in
            var firstError: Error?
            for url in urls {
                do { try FileManager.default.evictUbiquitousItem(at: url) } catch { firstError = firstError ?? error }
            }
            DispatchQueue.main.async {
                for url in urls { self?.recheck(CloudMonitor.key(url)) }
                completion(firstError)
            }
        }
    }
}
