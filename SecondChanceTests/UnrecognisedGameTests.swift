import Testing
import Foundation
@testable import SecondChance

/// A disc or download whose game isn't recognised: someone at the app is
/// asked what to do, and a headless run carries on as it always has.
@Suite("Unrecognised games")
struct UnrecognisedGameTests {
    @Test("A headless run installs an unrecognised game without asking", arguments: [
        ["NON_INTERACTIVE": "true"],
        ["DISK_1_PATH": "/nonexistent"],
        ["HER_INSTALLER_PATH": "/nonexistent.exe"],
    ])
    @MainActor
    func headlessInstallsAnyway(environment: [String: String]) throws {
        let input = WrappBuildInput(environment: environment, viewModel: nil)
        #expect(try input.askAboutUnrecognisedGame(.disk) == .installAnyway)
        #expect(try input.askAboutUnrecognisedGame(.herDownload) == .installAnyway)
    }

    @Test("Detection that matches nothing gives the game the builders ask about")
    func unknownSlugIsUnknownGame() {
        #expect(GameInfoProvider.shared.gameInfo(for: "unknown").id == GameInfo.unknownGame.id)
    }
}
