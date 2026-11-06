import AudioToolbox
import Foundation

/// Finder's interface sounds. They play as system sounds, so like Finder's they follow
/// System Settings › Sound › “Play user interface sound effects” and the alert volume.
enum UISound {
    private static let base = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/"

    /// Moving items to the Bin.
    static let trash = base + "dock/drag to trash.aif"
    /// A copy or move finishing (the same sound Finder plays).
    static let copy = base + "system/Volume Mount.aif"

    private static var ids: [String: SystemSoundID] = [:]

    static func play(_ path: String) {
        var id = ids[path] ?? 0
        if id == 0 {
            guard AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &id) == noErr else { return }
            ids[path] = id
        }
        AudioServicesPlaySystemSound(id)
    }
}
