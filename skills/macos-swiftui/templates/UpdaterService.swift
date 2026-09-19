import AppKit
import Sparkle

/// In-app updates via Sparkle. The feed and EdDSA public key live in Info.plist
/// (`SUFeedURL`, `SUPublicEDKey`). Debug builds never check on their own.
final class UpdaterService {
    private let controller: SPUStandardUpdaterController

    init() {
        #if DEBUG
        let startUpdater = false
        #else
        let startUpdater = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: startUpdater, updaterDelegate: nil, userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
