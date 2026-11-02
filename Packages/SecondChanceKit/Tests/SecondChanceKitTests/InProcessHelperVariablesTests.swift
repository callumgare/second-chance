import Foundation
import GameCatalog
import Testing
@testable import ProcessKit
@testable import SecondChanceKit
@testable import WindowsFormats
@testable import WineKit
@testable import WrappFormat
@testable import WrappLogging

/// Which in-process helpers a game's Wine is told to arm, by what its .exe
/// draws with (`GameGraphicsAPI`, tested on real-shaped programs in
/// WrappKit's tests).
struct InProcessHelperVariablesTests {
    private func variables(_ exe: String, _ api: GameGraphicsAPI, _ environment: [String: String] = [:]) -> [String: String] {
        Wine.inProcessHelperVariables(gameExe: exe, graphicsAPI: api, environment: environment)
    }

    @Test("Cursor lock arms unless the game draws with Direct3D")
    func armsCursorLockWhereCncDdrawMayDraw() {
        #expect(variables("Game.exe", .directDraw)["CURSOR_LOCK_EXE"] == "Game.exe")
        #expect(variables("Missing.exe", .unknown)["CURSOR_LOCK_EXE"] == "Missing.exe")
        let direct3D = variables("Secrets.exe", .direct3D)
        #expect(direct3D["CURSOR_LOCK_EXE"] == nil)
        // The other helpers don't depend on it.
        #expect(direct3D["NATIVE_MACOS_FULLSCREEN_EXE"] == "Secrets.exe")
    }

    @Test("Mode scaling arms unless the game draws through cnc-ddraw")
    func armsModeScalingWhereDirect3DMayDraw() {
        #expect(variables("Game.exe", .directDraw)["EMULATED_MODE_SCALING_EXE"] == nil)
        #expect(variables("Wolf.exe", .direct3D)["EMULATED_MODE_SCALING_EXE"] == "Wolf.exe")
        #expect(variables("Missing.exe", .unknown)["EMULATED_MODE_SCALING_EXE"] == "Missing.exe")
        // Its off switch.
        #expect(variables("Wolf.exe", .direct3D, ["SECOND_CHANCE_MODE_SCALING": "0"])["EMULATED_MODE_SCALING_EXE"] == nil)
    }

    @Test("A missing .exe draws with an unknown API, so both helpers that depend on it arm")
    func aMissingExeArmsBoth() {
        let missing = URL(fileURLWithPath: "/nonexistent/Missing.exe")
        let variables = Wine.inProcessHelperVariables(gameExe: missing, environment: [:])
        #expect(variables["CURSOR_LOCK_EXE"] == "Missing.exe")
        #expect(variables["EMULATED_MODE_SCALING_EXE"] == "Missing.exe")
    }

    @Test("A Big Fish Direct3D game, whose .exe can't say, gets no cursor lock")
    func goesByTheCatalog() {
        // Missing, so its imports can't say, as Armadillo's packing can't.
        let wrapped = URL(fileURLWithPath: "/nonexistent/Game.exe")
        let crystalSkull = GameInfoProvider.shared.gameInfo(for: "crystal-skull")
        #expect(Wine.inProcessHelperVariables(gameExe: wrapped, game: crystalSkull, environment: [:])["CURSOR_LOCK_EXE"] == nil)
    }
}
