import AppKit
import UniformTypeIdentifiers

/// Identifies a file or folder, either on this Mac or on an SSH host.
enum ItemRef: Hashable, Codable {
    case local(URL)
    case remote(host: String, path: String)

    var name: String {
        switch self {
        case .local(let url):
            return url.path == "/" ? (FileManager.default.displayName(atPath: "/")) : url.lastPathComponent
        case .remote(let host, let path):
            return path == "/" ? host : (path as NSString).lastPathComponent
        }
    }

    var parent: ItemRef? {
        switch self {
        case .local(let url):
            guard url.path != "/" else { return nil }
            return .local(url.deletingLastPathComponent())
        case .remote(let host, let path):
            guard path != "/" else { return nil }
            let parentPath = (path as NSString).deletingLastPathComponent
            return .remote(host: host, path: parentPath.isEmpty ? "/" : parentPath)
        }
    }

    func appending(_ component: String) -> ItemRef {
        switch self {
        case .local(let url):
            return .local(url.appendingPathComponent(component))
        case .remote(let host, let path):
            return .remote(host: host, path: (path as NSString).appendingPathComponent(component))
        }
    }

    var localURL: URL? {
        if case .local(let url) = self { return url }
        return nil
    }

    var remoteHost: String? {
        if case .remote(let host, _) = self { return host }
        return nil
    }

    var path: String {
        switch self {
        case .local(let url): return url.path
        case .remote(_, let path): return path
        }
    }

    var isRemote: Bool { remoteHost != nil }

    /// A stable key used to remember per-folder settings.
    var settingsKey: String {
        switch self {
        case .local(let url): return "file:" + url.standardizedFileURL.path
        case .remote(let host, let path): return "ssh:\(host):\(path)"
        }
    }
}

final class FileItem: NSObject {
    let ref: ItemRef
    let name: String
    let displayName: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let isSymlink: Bool
    let isAlias: Bool
    let size: Int64?
    let modified: Date?
    let created: Date?
    let lastOpened: Date?
    let added: Date?
    let kind: String
    let tags: [String]

    /// Loaded children when expanded in list or column view.
    var children: [FileItem]?

    init(ref: ItemRef, name: String, displayName: String? = nil, isDirectory: Bool, isPackage: Bool = false,
         isHidden: Bool, isSymlink: Bool = false, isAlias: Bool = false, size: Int64?, modified: Date?,
         created: Date? = nil, lastOpened: Date? = nil, added: Date? = nil, kind: String, tags: [String] = []) {
        self.ref = ref
        self.name = name
        self.displayName = displayName ?? name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.isAlias = isAlias
        self.size = size
        self.modified = modified
        self.created = created
        self.lastOpened = lastOpened
        self.added = added
        self.kind = kind
        self.tags = tags
    }

    /// Folders the user can navigate into (packages such as apps open instead).
    var isBrowsable: Bool { isDirectory && !isPackage }

    override var hash: Int { ref.hashValue }
    override func isEqual(_ object: Any?) -> Bool {
        (object as? FileItem)?.ref == ref
    }

    var iconOverride: NSImage?
    private var cachedIcon: NSImage?
    var icon: NSImage {
        if let iconOverride { return iconOverride }
        if let cachedIcon { return cachedIcon }
        let image: NSImage
        switch ref {
        case .local(let url):
            image = url.isFileURL ? NSWorkspace.shared.icon(forFile: url.path) : NSWorkspace.shared.icon(for: .folder)
        case .remote(_, let path):
            if isDirectory {
                image = NSWorkspace.shared.icon(for: .folder)
            } else {
                let ext = (path as NSString).pathExtension
                let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
                image = NSWorkspace.shared.icon(for: type)
            }
        }
        cachedIcon = image
        return image
    }

    static func local(_ url: URL) -> FileItem? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey,
                                         .contentModificationDateKey, .creationDateKey,
                                         .localizedTypeDescriptionKey, .tagNamesKey, .localizedNameKey,
                                         .isSymbolicLinkKey, .isAliasFileKey, .contentAccessDateKey,
                                         .addedToDirectoryDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let isDir = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        return FileItem(ref: .local(url),
                        name: url.lastPathComponent,
                        displayName: values.localizedName ?? url.lastPathComponent,
                        isDirectory: isDir,
                        isPackage: isPackage,
                        isHidden: (values.isHidden ?? false) || url.lastPathComponent.hasPrefix("."),
                        isSymlink: values.isSymbolicLink ?? false,
                        isAlias: (values.isAliasFile ?? false) && !(values.isSymbolicLink ?? false),
                        size: (isDir && !isPackage) ? nil : values.fileSize.map(Int64.init),
                        modified: values.contentModificationDate,
                        created: values.creationDate,
                        lastOpened: values.contentAccessDate,
                        added: values.addedToDirectoryDate,
                        kind: values.localizedTypeDescription ?? (isDir ? "Folder" : "Document"),
                        tags: values.tagNames ?? [])
    }

    static let localKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey,
                                               .contentModificationDateKey, .creationDateKey,
                                               .localizedTypeDescriptionKey, .tagNamesKey, .localizedNameKey,
                                               .isSymbolicLinkKey, .isAliasFileKey, .contentAccessDateKey,
                                               .addedToDirectoryDateKey]
}

// MARK: - Formatting

enum Fmt {
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func size(_ value: Int64?) -> String {
        guard let value else { return "--" }
        if value < 1000 { return value == 1 ? "1 byte" : "\(value) bytes" }
        return bytes.string(fromByteCount: value)
    }

    static func dateString(_ date: Date?) -> String {
        guard let date else { return "--" }
        return Fmt.date.string(from: date)
    }

    /// Finder shows free space with up to two decimals: “509.48 GB”, “507.7 GB”.
    static func available(_ bytes: Int64) -> String {
        let value = Double(bytes)
        let (amount, unit): (Double, String) = value >= 1e12 ? (value / 1e12, "TB") : (value >= 1e9 ? (value / 1e9, "GB") : (value / 1e6, "MB"))
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return "\(f.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)) \(unit)"
    }
}

// MARK: - Finder tags

enum FinderTag {
    static let all: [(name: String, color: NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow),
        ("Green", .systemGreen), ("Blue", .systemBlue), ("Purple", .systemPurple), ("Grey", .systemGray),
    ]

    static func color(for tag: String) -> NSColor? {
        let lower = tag.lowercased()
        if lower == "gray" { return .systemGray }
        return all.first { $0.name.lowercased() == lower }?.color
    }
}

extension NSColor {
    /// Text color Finder uses for hidden (dot) files, resolved for a view's appearance.
    static func hiddenItemText(for view: NSView) -> NSColor {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.39, green: 0.40, blue: 0.415, alpha: 1) : NSColor(srgbRed: 0.761, green: 0.765, blue: 0.765, alpha: 1)
    }
}
