import AppKit
import Sparkle

/// Checks GitHub releases for a newer Scout with Sparkle (SUFeedURL in Scout-Info.plist points at the latest
/// release's appcast.xml, which scripts/release.sh publishes).
///
/// Scheduled checks don't interrupt: a found update only shows a small Update button in the toolbar
/// (“gentle reminder”). Clicking it opens Sparkle's update window, which downloads the update and installs it
/// when Scout quits, or right away with Install and Relaunch.
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updater()
    static let availabilityChanged = Notification.Name("ScoutUpdateAvailabilityChanged")

    /// Version of the update waiting for the user, while the toolbar button should show.
    private(set) var availableVersion: String?
    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        // Debug builds have build number 1, so every release would look newer. SCOUT_UPDATER=1 turns updates on for
        // testing, and SCOUT_FEED_URL points them at another appcast (http://localhost is fine).
        #if DEBUG
        let start = ProcessInfo.processInfo.environment["SCOUT_UPDATER"] != nil
        #else
        let start = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: self, userDriverDelegate: self)
    }

    #if DEBUG
    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["SCOUT_FEED_URL"]
    }
    #endif

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Shows Sparkle's window: the waiting update if a scheduled check found one, otherwise a fresh check.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // Sparkle shows its own window for checks the user started; scheduled ones get the toolbar button.
        guard !handleShowingUpdate else { return }
        setAvailableVersion(update.displayVersionString)
    }

    func standardUserDriverWillFinishUpdateSession() {
        setAvailableVersion(nil)
    }

    private func setAvailableVersion(_ version: String?) {
        guard version != availableVersion else { return }
        availableVersion = version
        NotificationCenter.default.post(name: Updater.availabilityChanged, object: self)
    }
}
