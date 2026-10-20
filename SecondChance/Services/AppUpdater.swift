import Combine
import Foundation
import Logging
import Sparkle
import SwiftUI

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.Updates")

/// Checks the GitHub releases for a newer Second Chance and offers to install
/// it, through Sparkle. The feed and the key updates must be signed with are
/// in `Info.plist`; how a release publishes them is in docs/updates.md.
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// Sparkle's own answer: false while a check is already running, and
    /// always false when the updater is off.
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController?

    private init() {
        guard let reason = Self.disabledReason else {
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            self.controller = controller
            controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
            do {
                try controller.updater.start()
                logger.debug("Update checks started (feed \(controller.updater.feedURL?.absoluteString ?? "none"))")
            } catch {
                logger.error("Couldn't start update checks: \(error.localizedDescription)")
            }
            return
        }
        controller = nil
        logger.debug("Update checks are off: \(reason)")
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Why the updater mustn't run, or nil when it should. A Debug build
    /// would replace itself with the latest release, a headless build has no
    /// one to ask, and the test host would put a dialog in front of the tests.
    /// `SECOND_CHANCE_UPDATES=1` or `0` overrides all of these.
    private static var disabledReason: String? {
        let env = ProcessInfo.processInfo.environment
        if let forced = env["SECOND_CHANCE_UPDATES"] {
            return forced == "1" ? nil : "SECOND_CHANCE_UPDATES=\(forced)"
        }
        if CLIBuilder.isEnabled { return "headless build" }
        if env["XCTestConfigurationFilePath"] != nil { return "running tests" }
        #if DEBUG
        return "Debug build"
        #else
        return nil
        #endif
    }
}

/// The app menu's Check for Updates… item.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
