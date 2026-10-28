import AppKit

enum Symbols {
    /// Loads a public or system-private SF Symbol (Finder uses a few private ones, like “appstore”).
    static func image(_ name: String, size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSImage? {
        var image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        if image == nil {
            let selector = NSSelectorFromString("_imageWithSystemSymbolName:")
            if NSImage.responds(to: selector) {
                image = NSImage.perform(selector, with: name)?.takeUnretainedValue() as? NSImage
            }
        }
        if let size, let configured = image?.withSymbolConfiguration(.init(pointSize: size, weight: weight)) {
            return configured
        }
        return image
    }
}
