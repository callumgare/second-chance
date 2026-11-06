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

    @Test("What the launch declares the game draws with beats its .exe's imports")
    func theLaunchDeclaresTheGraphics() {
        // Missing, so its imports can't say; Iji's say DirectDraw (it imports
        // ddraw.dll) while it draws with Direct3D, which it loads itself.
        let exe = URL(fileURLWithPath: "/nonexistent/Iji.exe")
        let declared = RecordedLaunch(program: "wine:C:/Iji.exe", options: ["wine.graphics": "direct-3d"],
                                      format: RecordedLaunch.currentFormat)
        let graphics = Wine.graphicsAPI(gameExe: exe, game: nil, launch: declared)
        #expect(graphics.api == .direct3D)
        #expect(graphics.declared)
        #expect(Wine.inProcessHelperVariables(gameExe: exe, launch: declared, environment: [:])["EMULATED_MODE_SCALING_EXE"] == "Iji.exe")
        let older = RecordedLaunch(program: "wine:C:/Iji.exe")
        #expect(Wine.graphicsAPI(gameExe: exe, game: nil, launch: older).declared == false)
    }

    @Test("A launch that says what it wants gets cursor lock only when it asks, whatever the game draws with")
    func theLaunchChoosesCursorLock() {
        let asks = RecordedLaunch(program: "wine:C:/Game.exe", options: ["wine.mouse": "grab-early"], format: RecordedLaunch.currentFormat)
        let doesnt = RecordedLaunch(program: "wine:C:/Iji.exe", format: RecordedLaunch.currentFormat)
        let older = RecordedLaunch(program: "wine:C:/Game.exe")
        func lock(_ launch: RecordedLaunch, _ api: GameGraphicsAPI) -> String? {
            Wine.inProcessHelperVariables(gameExe: "Game.exe", graphicsAPI: api, launch: launch, environment: [:])["CURSOR_LOCK_EXE"]
        }
        #expect(lock(asks, .direct3D) == "Game.exe")
        // Free: cnc-ddraw never takes the mouse, so nothing gets it to.
        let free = RecordedLaunch(program: "wine:C:/Game.exe", options: ["wine.mouse": "free"], format: RecordedLaunch.currentFormat)
        #expect(lock(free, .directDraw) == nil)
        // Iji imports ddraw.dll and d3d8.dll: inferred, it would have had the lock.
        #expect(lock(doesnt, .unknown) == nil)
        #expect(lock(doesnt, .directDraw) == nil)
        // One recorded before the option is inferred, as it was.
        #expect(lock(older, .directDraw) == "Game.exe")
        #expect(lock(older, .direct3D) == nil)
    }

    @Test("--wine.window overrides native fullscreen: windowed leaves it unarmed, fullscreen forces it")
    func theLaunchOverridesFullscreen() {
        func variables(_ window: String?) -> [String: String] {
            let launch = RecordedLaunch(program: "wine:C:/Game.exe", options: window.map { ["wine.window": $0] } ?? [:],
                                        format: RecordedLaunch.currentFormat)
            return Wine.inProcessHelperVariables(gameExe: "Game.exe", graphicsAPI: .unknown, launch: launch, environment: [:])
        }
        #expect(variables(nil)["NATIVE_MACOS_FULLSCREEN_EXE"] == "Game.exe")
        #expect(variables(nil)["NATIVE_MACOS_FULLSCREEN_FORCE"] == nil)
        #expect(variables("windowed")["NATIVE_MACOS_FULLSCREEN_EXE"] == nil)
        #expect(variables("fullscreen")["NATIVE_MACOS_FULLSCREEN_FORCE"] == "1")
    }

    @Test("--wine.quit-key gives the quit watch its keys in canonical form, as written")
    func theLaunchNamesAQuitKey() {
        func key(_ options: [String: String]) -> String? {
            let launch = RecordedLaunch(program: "wine:C:/Iji/iji.exe", options: options, format: RecordedLaunch.currentFormat)
            return Wine.inProcessHelperVariables(gameExe: "iji.exe", graphicsAPI: .direct3D, launch: launch, environment: [:])["QUIT_KEY"]
        }
        #expect(key(["wine.quit-key": "f12"]) == "f12")
        #expect(key(["wine.quit-key": "f12:hold=5s"]) == "f12:hold=5000ms")
        #expect(key(["wine.quit-key": "f12:hold=1.5s"]) == "f12:hold=1500ms")
        // Several keys are pressed in turn, as written, the quit keys' 2.5 s
        // between each two spelled out unless the keys say otherwise.
        #expect(key(["wine.quit-key": "escape esc return"]) == "escape wait=2500ms escape wait=2500ms return")
        #expect(key(["wine.quit-key": "up return*2"]) == "up wait=2500ms return wait=2500ms return")
        #expect(key(["wine.quit-key": "escape wait=0 escape"]) == "escape wait=0ms escape")
        #expect(key(["wine.quit-key": "gap=300ms up up wait=1s return"]) == "up wait=300ms up wait=1000ms return")
        #expect(key(["wine.quit-key": "escape wait=1s"]) == nil)
        #expect(key(["wine.quit-key": "f13"]) == nil)
        #expect(key([:]) == nil)
    }

    @Test("--wine.quit-confirm-key gives the quit watch the keys a second Quit presses, only beside a quit key")
    func theLaunchNamesConfirmKeys() {
        func variables(_ options: [String: String]) -> [String: String] {
            let launch = RecordedLaunch(program: "wine:C:/IcyTower/icytower13.exe", options: options, format: RecordedLaunch.currentFormat)
            return Wine.inProcessHelperVariables(gameExe: "icytower13.exe", graphicsAPI: .directDraw, launch: launch, environment: [:])
        }
        let both = variables(["wine.quit-key": "escape", "wine.quit-confirm-key": "escape escape"])
        #expect(both["QUIT_KEY"] == "escape")
        #expect(both["QUIT_CONFIRM_KEY"] == "escape wait=2500ms escape")
        // Icy Tower's: the quit key pressed once, the confirm key held.
        let icy = variables(["wine.quit-key": "escape", "wine.quit-confirm-key": "escape:hold=5s"])
        #expect(icy["QUIT_KEY"] == "escape")
        #expect(icy["QUIT_CONFIRM_KEY"] == "escape:hold=5000ms")
        #expect(variables(["wine.quit-confirm-key": "escape"])["QUIT_CONFIRM_KEY"] == nil)
    }
}
