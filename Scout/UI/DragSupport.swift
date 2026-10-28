import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    static let scoutRefs = NSPasteboard.PasteboardType("io.matej.scout.refs")
}

/// Drag source for one item. Local files are plain file URLs, so they can be
/// dropped anywhere. Remote files are file promises: dropping one on the
/// Desktop or into another app downloads it over SSH.
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
        if case .local = ref { return [.scoutRefs, .fileURL, .string] }
        return [.scoutRefs] + super.writableTypes(for: pasteboard)
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == .scoutRefs || type == .fileURL || type == .string { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .scoutRefs:
            return try? JSONEncoder().encode([ref])
        case .fileURL:
            return ref.localURL.map { ($0 as NSURL).pasteboardPropertyList(forType: .fileURL) } ?? nil
        case .string:
            return ref.path
        default:
            return super.pasteboardPropertyList(forType: type)
        }
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

    static func writer(for item: FileItem) -> NSPasteboardWriting? {
        if case .local(let url) = item.ref, !url.isFileURL { return nil }
        if case .remote(_, let path) = item.ref, path.isEmpty { return nil }
        return ItemDragWriter(item: item, delegate: PromiseDelegate.shared)
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

// MARK: - Terminal

enum Terminal {
    static func open(_ ref: ItemRef) {
        switch ref {
        case .local(let url):
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        case .remote(let host, let path):
            let cd = path.isEmpty ? "" : "cd \(shq(path)) 2>/dev/null; "
            let command = "ssh -t \(shq(host)) \(shq(cd + "exec \"$SHELL\" -l"))"
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let script = NSAppleScript(source: "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell")
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
        }
    }
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
