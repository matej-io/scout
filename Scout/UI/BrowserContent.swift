import AppKit

/// One of the four Finder view styles living inside a pane.
protocol BrowserContent: NSViewController {
    var pane: PaneViewController? { get set }
    /// Shows a new listing. Selection is restored by ref when possible.
    func display(_ items: [FileItem], select refs: [ItemRef]?)
    var selectedItems: [FileItem] { get }
    func select(_ refs: [ItemRef])
    func beginRename(_ ref: ItemRef)
    /// An item's name is being edited inline. Rebuilding the view would end the edit.
    var isEditingName: Bool { get }
    /// The view that should take keyboard focus.
    var focusView: NSView { get }
    /// Folder that “New Folder” and “Paste” go into, when it differs from the pane location (column view).
    var targetFolder: ItemRef? { get }
    /// A subfolder shown inline (expanded row, deeper column) changed on disk.
    func childrenChanged(in folder: ItemRef)
    /// Whether a folder's contents can be shown in place (expanded row, next column), so a new item
    /// created inside it can be revealed and renamed there.
    var showsSubfolderContents: Bool { get }
    /// A new item was created inside `folder`, which is shown in this view: reveal it and start renaming it.
    func revealNewItem(_ ref: ItemRef, in folder: ItemRef)
    func iconSizeChanged()
    /// A View Options (⌘J) setting changed.
    func viewOptionsChanged()
}

extension BrowserContent {
    var targetFolder: ItemRef? { nil }
    var isEditingName: Bool { false }
    func childrenChanged(in folder: ItemRef) {}
    var showsSubfolderContents: Bool { false }
    func revealNewItem(_ ref: ItemRef, in folder: ItemRef) { childrenChanged(in: folder) }
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

/// Finder's click-to-rename: a single click on the name of the only selected item starts renaming it,
/// once the double-click interval passes without a second click (so opening a file never renames it).
final class ClickRename {
    private var armed: (start: NSPoint, fire: () -> Void)?
    private var pending: DispatchWorkItem?

    func cancel() {
        armed = nil
        pending?.cancel()
        pending = nil
    }

    /// Call on mouse down, before the view's own handling. `eligible` says the click hit the name of the sole selection.
    func mouseDown(_ event: NSEvent, eligible: Bool, fire: @escaping () -> Void) {
        cancel()
        guard eligible, event.clickCount == 1,
              event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty else { return }
        armed = (event.locationInWindow, fire)
    }

    /// Call with the mouse up (also right after a mouse down whose tracking loop swallowed it). A drag in between cancels.
    func mouseUp(_ event: NSEvent?) {
        guard let armed, let event, event.type == .leftMouseUp else { return }
        self.armed = nil
        guard abs(event.locationInWindow.x - armed.start.x) < 3, abs(event.locationInWindow.y - armed.start.y) < 3 else { return }
        let work = DispatchWorkItem(block: armed.fire)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
}
