import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    static let scoutRefs = NSPasteboard.PasteboardType("io.matej.scout.refs")
}

/// Drag source for a remote item: a file promise, so dropping it on the Desktop
/// or into another app downloads it over SSH.
final class ItemDragWriter: NSFilePromiseProvider {
    let ref: ItemRef

    init(item: FileItem, delegate: NSFilePromiseProviderDelegate) {
        self.ref = item.ref
        super.init()
        let ext = (item.name as NSString).pathExtension
        self.fileType = item.isDirectory ? UTType.folder.identifier : (UTType(filenameExtension: ext) ?? .data).identifier
        self.delegate = delegate
        self.userInfo = item.ref
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.scoutRefs] + super.writableTypes(for: pasteboard)
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == .scoutRefs { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .scoutRefs { return try? JSONEncoder().encode([ref]) }
        return super.pasteboardPropertyList(forType: type)
    }
}

final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    static let shared = PromiseDelegate()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? ItemRef)?.name ?? "Untitled"
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard case .remote(let host, let path)? = provider.userInfo as? ItemRef else {
            completionHandler(ScoutError("Nothing to write."))
            return
        }
        switch FileOps.download(host: host, path: path, to: url) {
        case .success: completionHandler(nil)
        case .failure(let error): completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}

enum DragSupport {
    static let types: [NSPasteboard.PasteboardType] = [.scoutRefs, .fileURL]

    /// Local files are dragged as plain file URLs, like Finder does, so any app can take them.
    static func writer(for item: FileItem) -> NSPasteboardWriting? {
        switch item.ref {
        case .local(let url):
            guard url.isFileURL else { return nil }
            let pbItem = NSPasteboardItem()
            pbItem.setData((try? JSONEncoder().encode([item.ref])) ?? Data(), forType: .scoutRefs)
            pbItem.setString(url.absoluteString, forType: .fileURL)
            return pbItem
        case .remote(_, let path):
            guard !path.isEmpty else { return nil }
            return ItemDragWriter(item: item, delegate: PromiseDelegate.shared)
        }
    }

    static func refs(from pasteboard: NSPasteboard) -> [ItemRef] {
        if let data = pasteboard.data(forType: .scoutRefs), let refs = try? JSONDecoder().decode([ItemRef].self, from: data), !refs.isEmpty {
            // Collect refs from every pasteboard item (multi-item drags).
            var all: [ItemRef] = []
            for item in pasteboard.pasteboardItems ?? [] {
                if let d = item.data(forType: .scoutRefs), let r = try? JSONDecoder().decode([ItemRef].self, from: d) { all += r }
            }
            return all.isEmpty ? refs : all
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map { .local($0) }
    }

    /// Finder semantics: same volume moves, different volume copies; ⌥ forces copy, ⌘ forces move.
    static func operation(for info: NSDraggingInfo, destination: ItemRef) -> NSDragOperation {
        let refs = refs(from: info.draggingPasteboard)
        guard !refs.isEmpty else { return [] }
        if refs.allSatisfy({ $0.parent == destination || $0 == destination }) { return [] }
        if case .local(let url) = destination, url == Location.trashURL { return .move }
        let mask = info.draggingSourceOperationMask
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) && mask.contains(.copy) { return .copy }
        if flags.contains(.command) && mask.contains(.move) { return .move }
        let sameVolume = refs.allSatisfy { sameVolume($0, destination) }
        if sameVolume && mask.contains(.move) { return .move }
        if mask.contains(.copy) { return .copy }
        return mask.contains(.generic) ? .generic : []
    }

    static func accept(_ info: NSDraggingInfo, destination: ItemRef, window: NSWindow?) -> Bool {
        let refs = refs(from: info.draggingPasteboard)
        guard !refs.isEmpty else { return false }
        noteDrop()
        if case .local(let url) = destination, url == Location.trashURL {
            let urls = refs.compactMap(\.localURL)
            if !urls.isEmpty { FileOps.trash(urls) { _, _ in } }
            return true
        }
        let op = operation(for: info, destination: destination)
        guard op != [] else { return false }
        FileOps.transfer(refs, to: destination, move: op == .move, window: window)
        return true
    }

    private static func sameVolume(_ a: ItemRef, _ b: ItemRef) -> Bool {
        switch (a, b) {
        case (.local(let u1), .local(let u2)):
            let v1 = try? u1.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
            let v2 = try? u2.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
            if let v1, let v2 { return v1.isEqual(v2) }
            return false
        case (.remote(let h1, _), .remote(let h2, _)):
            return h1 == h2
        default:
            return false
        }
    }
}

// MARK: - Clipboard

enum Clipboard {
    static func write(_ items: [FileItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var objects: [NSPasteboardWriting] = []
        for item in items {
            let pbItem = NSPasteboardItem()
            pbItem.setData((try? JSONEncoder().encode([item.ref])) ?? Data(), forType: .scoutRefs)
            if let url = item.ref.localURL, url.isFileURL {
                pbItem.setString(url.absoluteString, forType: .fileURL)
                pbItem.setString(url.path, forType: .string)
            } else {
                pbItem.setString(item.ref.path, forType: .string)
            }
            objects.append(pbItem)
        }
        pb.writeObjects(objects)
    }

    static var refs: [ItemRef] { DragSupport.refs(from: .general) }
}

// MARK: - Thumbnails

final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    /// Calls back with a Quick Look thumbnail for local files that have one (images, PDFs, movies…).
    func thumbnail(for item: FileItem, size: CGFloat, completion: @escaping (NSImage) -> Void) {
        guard case .local(let url) = item.ref, url.isFileURL, !item.isBrowsable else { return }
        let key = "\(url.path)#\(Int(size))#\(item.modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let image = cache.object(forKey: key) { completion(image); return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale,
                                                   representationTypes: .thumbnail)
        request.iconMode = true
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            let image = rep.nsImage
            self?.cache.setObject(image, forKey: key)
            DispatchQueue.main.async { completion(image) }
        }
    }
}

// MARK: - Spring-loaded folders

/// Finder-style spring-loading: hold a dragged item over a folder for the system
/// spring-loading delay (System Settings › Accessibility) and the folder blinks and opens.
/// Moving on before the delay does nothing.
final class SpringLoader {
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "com.apple.springing.enabled") as? Bool ?? true }
    static var delay: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "com.apple.springing.delay")
        return value > 0 ? value : 0.5
    }

    private var target: AnyHashable?
    private var timer: Timer?
    private let blink: (AnyHashable, Bool) -> Void
    private let open: (AnyHashable) -> Void

    /// `blink` turns the target's highlight on/off; `open` springs it open.
    init(blink: @escaping (AnyHashable, Bool) -> Void, open: @escaping (AnyHashable) -> Void) {
        self.blink = blink
        self.open = open
    }

    /// Call on every drag update with the folder under the pointer (nil when not over a folder).
    func hover(_ key: AnyHashable?) {
        guard key != target else { return }
        cancel()
        target = key
        guard let key, SpringLoader.isEnabled else { return }
        schedule(after: SpringLoader.delay) { [weak self] in self?.fire(key) }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        target = nil
    }

    private func schedule(after interval: TimeInterval, _ block: @escaping () -> Void) {
        let t = Timer(timeInterval: interval, repeats: false) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fire(_ key: AnyHashable) {
        // Two quick blinks, then open — like Finder.
        let steps: [Bool] = [false, true, false, true]
        func step(_ i: Int) {
            guard target == key else { return }
            if i == steps.count {
                target = nil
                open(key)
                return
            }
            blink(key, steps[i])
            schedule(after: 0.07) { step(i + 1) }
        }
        step(0)
    }
}

extension DragSupport {
    /// Time of the last accepted drop, used to decide whether a spring-loaded window stays open.
    static var lastDrop = Date.distantPast
    static func noteDrop() { lastDrop = Date() }
}
