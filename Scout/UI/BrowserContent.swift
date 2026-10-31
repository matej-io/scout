import AppKit

/// One of the four Finder view styles living inside a pane.
protocol BrowserContent: NSViewController {
    var pane: PaneViewController? { get set }
    /// Shows a new listing. Selection is restored by ref when possible.
    func display(_ items: [FileItem], select refs: [ItemRef]?)
    var selectedItems: [FileItem] { get }
    func select(_ refs: [ItemRef])
    func beginRename(_ ref: ItemRef)
    /// The view that should take keyboard focus.
    var focusView: NSView { get }
    /// Folder that “New Folder” and “Paste” go into, when it differs from the pane location (column view).
    var targetFolder: ItemRef? { get }
    /// A subfolder shown inline (expanded row, deeper column) changed on disk.
    func childrenChanged(in folder: ItemRef)
    func iconSizeChanged()
    /// A View Options (⌘J) setting changed.
    func viewOptionsChanged()
}

extension BrowserContent {
    var targetFolder: ItemRef? { nil }
    func childrenChanged(in folder: ItemRef) {}
    func iconSizeChanged() {}
    func viewOptionsChanged() {}
}

/// Shared keyboard handling for file views, matching Finder.
enum BrowserKeys {
    /// Returns true when the event was handled.
    static func handle(_ event: NSEvent, pane: PaneViewController?) -> Bool {
        guard let pane else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76: // Return, Enter → rename
            if flags.isEmpty { pane.renameSelection(nil); return true }
        case 125: // Down
            if flags.contains(.command) { pane.openSelection(nil); return true }
        case 126: // Up
            if flags.contains(.command) { pane.goEnclosingFolder(nil); return true }
        case 49: // Space → Quick Look
            if flags.isEmpty || flags == .option {
                (pane.view.window?.windowController as? MainWindowController)?.togglePreviewPanel(nil)
                return true
            }
        case 51, 117: // Delete
            if flags.contains(.command) { pane.moveToTrash(nil); return true }
        case 48: // Tab → switch pane when split
            if flags == .option {
                (pane.view.window?.windowController as? MainWindowController)?.switchPane(nil)
                return true
            }
        default:
            break
        }
        return false
    }
}
