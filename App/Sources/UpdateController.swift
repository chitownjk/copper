import AppKit
#if !DEBUG
import Sparkle
#endif

/// Owns Sparkle 2 for notarized Developer ID Release builds.
///
/// Camera system extension may need re-approval after an update. Sparkle
/// replaces the app bundle (which embeds the extension); we do not automate
/// further extension replacement.
final class UpdateController {
    static let shared = UpdateController()

    #if !DEBUG
    private var updaterController: SPUStandardUpdaterController?
    #endif

    private init() {}

    /// Headless CLI flags (--recover-orphans, camera extension install, etc.)
    /// must never start Sparkle. Debug / Apple Development builds also skip it.
    func startIfAppropriate(headless: Bool) {
        #if DEBUG
        _ = headless
        return
        #else
        guard !headless, updaterController == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Info.plist keeps SUEnableAutomaticChecks false so Debug never
        // auto-checks even if this type is constructed by mistake.
        controller.updater.automaticallyChecksForUpdates = true
        controller.startUpdater()
        updaterController = controller
        #endif
    }

    func checkForUpdates() {
        #if !DEBUG
        updaterController?.checkForUpdates(nil)
        #endif
    }

    var canCheckForUpdates: Bool {
        #if DEBUG
        return false
        #else
        return updaterController?.updater.canCheckForUpdates ?? false
        #endif
    }
}
