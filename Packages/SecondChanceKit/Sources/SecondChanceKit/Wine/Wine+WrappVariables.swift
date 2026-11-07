//
//  Wine+WrappVariables.swift
//  Shared
//
//  The variables a wrapp adds for its own Wine programs: for the whole
//  session, and for the game, to arm the in-process helpers.
//  See docs/wine-in-process-helpers.md.

import Foundation
import GameCatalog
import KeyNotation
import Logging
import WrappFormat

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.WrappVariables")

nonisolated extension Wine {
    /// The directory WrappPuppeteer gave the wrapp for its control sockets,
    /// when it started the wrapp; nil for every player's launch.
    public static func puppetDirectory(in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let directory = environment["SECOND_CHANCE_PUPPET_DIR"], !directory.isEmpty else { return nil }
        return directory
    }

    /// Variables a wrapp sets on itself at start-up, so that every Wine
    /// process it starts inherits them — the desktop, the game, Steam — and
    /// Second Chance's own installer runs don't.
    ///
    /// `NATIVE_FULLSCREEN_BELOW_NOTCH` shows Wine a notched display without the
    /// strip the notch sits in, which a fullscreen Space leaves out, so a game
    /// in one gets mouse positions that match its picture. It has to reach
    /// explorer.exe, which registers the displays the game sees, which is why
    /// it isn't among `inProcessHelperVariables`. Native fullscreen's off switch
    /// turns it off too.
    public static func wrappSessionVariables(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        guard environment["SECOND_CHANCE_NATIVE_FULLSCREEN"] != "0" else { return [:] }
        return ["NATIVE_FULLSCREEN_BELOW_NOTCH": "1"]
    }

    /// The variables that arm the in-process helpers bundled into Wine's Mac
    /// driver for the game whose .exe is at `gameExe`: native fullscreen puts
    /// the game's window into a real macOS fullscreen Space, cursor lock gets
    /// cnc-ddraw to take the mouse without swallowing the player's first click
    /// (only in a game that may draw through cnc-ddraw: `GameGraphicsAPI`),
    /// mode scaling scales a Direct3D game's picture up to the display when
    /// Wine is emulating the display mode the game switched to (only in a game
    /// that may draw with Direct3D, or whose launch sets a display mode, whose
    /// GDI picture it puts where the mouse is), quit watch tells the wrapp when the game
    /// first drew and whether it was asked to quit, and puppet control (only when WrappPuppeteer
    /// started the wrapp) lets it see and click the game. Every Mac-driver
    /// process loads them, so each is told which one is the game (by the
    /// .exe's name, which Wine puts in the process's argv[0]), and a Wine
    /// program passes its environment on to the programs it starts — so these
    /// work set on Steam as well as on the game.
    /// See docs/wine-in-process-helpers.md.
    ///
    /// Cursor lock is the launch's to ask for (`--wine.mouse=grab-early`); a launch
    /// recorded before it could gets it when the game may draw through
    /// cnc-ddraw, as every wrapp did then, as does no launch. `--wine.window`
    /// overrides native fullscreen.
    public static func inProcessHelperVariables(
        gameExe exeURL: URL, game: GameInfo? = nil, launch: RecordedLaunch? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        inProcessHelperVariables(gameExe: exeURL.lastPathComponent, graphicsAPI: graphicsAPI(gameExe: exeURL, game: game, launch: launch).api,
                                 launch: launch, environment: environment)
    }

    /// What the game at `gameExe` draws with: what its launch declares
    /// (`--wine.graphics`), as a game that loads Direct3D itself doesn't
    /// import it; for a launch recorded before that, the .exe's imports, and
    /// the catalog for one whose imports Armadillo hides (Big Fish's). The
    /// helpers a game is started with and those the wrapp expects to arm both
    /// come from this, so they can't disagree.
    public static func graphicsAPI(
        gameExe: URL, game: GameInfo?, launch: RecordedLaunch?
    ) -> (api: GameGraphicsAPI, declared: Bool) {
        if let declared = launch.flatMap({ GameGraphicsAPI(declared: $0.options["wine.graphics"]) }) { return (declared, true) }
        return (GameGraphicsAPI(exeAt: gameExe, game: game), false)
    }

    /// The same, for a game whose launch declares what it draws with.
    public static func inProcessHelperVariables(
        gameExe exeURL: URL, declared graphicsAPI: GameGraphicsAPI, launch: RecordedLaunch? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        inProcessHelperVariables(gameExe: exeURL.lastPathComponent, graphicsAPI: graphicsAPI, launch: launch, environment: environment)
    }

    /// The same, for the .exe called `gameExe` that draws with `graphicsAPI`.
    static func inProcessHelperVariables(
        gameExe: String, graphicsAPI: GameGraphicsAPI, launch: RecordedLaunch? = nil, environment: [String: String]
    ) -> [String: String] {
        var env: [String: String] = [:]
        // SECOND_CHANCE_NATIVE_FULLSCREEN=0 leaves native fullscreen unarmed — a
        // debug switch for telling its main-thread polling apart from other causes.
        // A launch that says --wine.window=windowed keeps the game in its
        // window; --wine.window=fullscreen makes it fullscreen whatever it asks.
        if environment["SECOND_CHANCE_NATIVE_FULLSCREEN"] != "0", !(launch?.keepsWindowed ?? false) {
            env["NATIVE_MACOS_FULLSCREEN_EXE"] = gameExe
            if launch?.forcesFullscreen == true { env["NATIVE_MACOS_FULLSCREEN_FORCE"] = "1" }
        }
        // SECOND_CHANCE_CURSOR_LOCK=0 leaves cursor lock unarmed, bringing back
        // cnc-ddraw's swallowed first click — for comparison. A Direct3D game
        // never goes through cnc-ddraw, and the lock's middle clicks would
        // only close the menus a player opens from the menu bar.
        let cursorLock = launch.map { $0.cursorLock(inferred: graphicsAPI.mayUseCncDdraw) } ?? graphicsAPI.mayUseCncDdraw
        if environment["SECOND_CHANCE_CURSOR_LOCK"] != "0", cursorLock {
            env["CURSOR_LOCK_EXE"] = gameExe
        }
        // SECOND_CHANCE_MODE_SCALING=0 leaves mode scaling unarmed, so a game
        // that switches the display mode draws into a corner of its window —
        // for comparison. The prefix's EmulateModeset (WineManager) stays on.
        // A launch that sets a display mode (--wine.display-mode) gets it
        // whatever the game draws with: Wine scales a GDI game's picture up
        // but draws it off-centre, which the helper puts right.
        if environment["SECOND_CHANCE_MODE_SCALING"] != "0", graphicsAPI.mayUseDirect3D || launch?.displayMode != nil {
            env["EMULATED_MODE_SCALING_EXE"] = gameExe
        }
        // Quit watch only reports, so it has no off switch: what it says
        // lets the wrapp tell a game that quit before it drew anything from
        // a player quitting (GameQuitCheck).
        env["QUIT_WATCH_EXE"] = gameExe
        // A launch that says --wine.quit-key has the quit watch press those
        // keys when the app is asked to quit, and with --wine.quit-confirm-key,
        // press those when it's asked again soon after: in canonical form,
        // every hold and every wait between presses explicit, the quit keys'
        // usual gap among them (RecordedLaunch.quitKeyGapMilliseconds), which
        // the helper does exactly (docs/wine-in-process-helpers.md#quit-keys).
        if let launch {
            do {
                let gap = RecordedLaunch.quitKeyGapMilliseconds
                if let keys = try launch.quitKeySequence() {
                    env["QUIT_KEY"] = keys.canonical(defaultGapMilliseconds: gap)
                    if let confirm = try launch.quitConfirmKeySequence() {
                        env["QUIT_CONFIRM_KEY"] = confirm.canonical(defaultGapMilliseconds: gap)
                    }
                }
            } catch {
                // Planning refuses keys it can't read, so only a wrapp built
                // by something else gets here: it quits as Wine does.
                logger.error("The launch's quit keys can't be read, so Quit goes to the game as Wine's: \(error)")
                env["QUIT_KEY"] = nil
                env["QUIT_CONFIRM_KEY"] = nil
            }
        }
        // Puppet control arms only when WrappPuppeteer started the wrapp,
        // which it marks by passing the directory for the helper's socket.
        if puppetDirectory(in: environment) != nil {
            env["PUPPET_CONTROL_EXE"] = gameExe
        }
        return env
    }

    /// The variables that keep the windows and Dock icon of the program
    /// running `exe` (or, for `*`, of every program they reach) off the
    /// screen, except while `showFile` exists: Big Fish's Game Manager, which
    /// people only see to sign in (the wine module's `InProcessHelpers/hidden_windows.m`).
    public static func hiddenWindowsVariables(exe: String, showFile: URL) -> [String: String] {
        ["HIDDEN_WINDOWS_EXE": exe, "HIDDEN_WINDOWS_SHOW_FILE": showFile.path]
    }
}
