import Foundation
import GameCatalog
@testable import SecondChanceKit
import Testing

/// Drives a real Game Manager. Off unless BIG_FISH_SMOKE_WRAPP names a wrapp
/// (or a folder shaped like one: Contents/SharedSupport/wine and /prefix,
/// Contents/Frameworks) whose prefix has the Game Manager installed.
@Suite("Big Fish Game Manager (real)",
       .enabled(if: ProcessInfo.processInfo.environment["BIG_FISH_SMOKE_WRAPP"] != nil,
                "Set BIG_FISH_SMOKE_WRAPP to a wrapp with the Game Manager installed"))
struct BigFishGameManagerSmokeTests {
    @Test func startsReadsAndStops() async throws {
        let wrapp = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BIG_FISH_SMOKE_WRAPP"]))
        let manager = BigFishGameManager(wrappPath: wrapp)
        #expect(manager.isInstalled)
        // Only one Game Manager runs in a prefix: a second hands over to the
        // first and exits. So never leave one running.
        await manager.shutdown(timeout: 30)
        try await manager.start(timeout: 180)
        let signedIn = try await manager.isSignedIn()
        if signedIn {
            #expect(try await !manager.ownedGames().isEmpty)
        }
        // A wrapp-shaped folder whose prefix has White Wolf installed, as the
        // one this was first run on had, sees it ready and finds its folder.
        let wolf = try #require(BigFishSKU("F2435T1L1"))
        if let game = manager.installedGame(wolf) {
            #expect(try await manager.status(of: wolf)?.phase == .ready)
            #expect(game.launcher.hasSuffix(".exe"))
        }
        await manager.shutdown(timeout: 30)
        #expect(!manager.isRunning())
    }
}
