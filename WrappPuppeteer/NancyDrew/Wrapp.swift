//
//  Wrapp.swift
//  WrappPuppeteer
//
//  What the Nancy Drew scenario needs to know about a Second Chance wrapp,
//  read from its AppSettings.plist, and how its modules behave under test
//  (TestModules.swift).

import Foundation
import GameCatalog
import SecondChanceKit
import Logging
import PuppeteerCore

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.Wrapp")

struct Wrapp {
    let appPath: String
    /// The engine setting, for logging.
    let engineSetting: String
    /// The modules the wrapp runs; nil when its settings can't be read.
    let composition: Composition?
    /// What each of them means under test.
    let modules: TestModules
    /// The game's slug (`GameInfoProvider`'s id), which names its splash
    /// screens' reference images.
    let gameSlug: String
    let gameExeName: String
    let winePrefix: URL
    /// What a Wine game draws with, from its .exe; only a DirectDraw game
    /// goes through cnc-ddraw, which can swallow its first click.
    let graphics: GameGraphicsAPI

    /// The shape of the picture every game draws, width over height: they
    /// all run at 640x480, 800x600 or 1024x768. On a display of another
    /// shape the wrapp shows it at this shape, with black bars beside it.
    static let pictureAspect = 4.0 / 3.0

    /// Whether Wine runs the game, Steam or not.
    var runsInWine: Bool { composition?.has(.wine) ?? false }

    /// The process that owns the game's window: the game's own `.exe`
    /// unless the module that starts it says otherwise.
    var gameProcessName: String { modules.launcher?.gameProcessName ?? gameExeName }

    /// Whether the game is judged in focus by its window being fullscreen,
    /// rather than by activating its app (`TestModule`).
    var judgesFocusByFullscreen: Bool { modules.launcher?.judgesFocusByFullscreen ?? false }

    var activatesForFocus: Bool { !judgesFocusByFullscreen }

    /// Whether a module shows a notice over the game's window for a while
    /// after it starts: Steam's overlay ("Press Shift+Tab to begin"), in the
    /// window's bottom-right corner.
    var showsSteamOverlay: Bool { modules.all.contains { $0.showsOverlayNotice } }

    /// The corner Steam's overlay notice takes, in points: it is about 285
    /// by 90 points, and this leaves room around it.
    static let steamOverlayNoticeSize = CGSize(width: 340, height: 120)

    /// How far down a fullscreen window macOS's title bar can reach, in
    /// points, when the cursor at the top of the screen shows it: about 60
    /// on a display without a notch, below the menu bar's place, and 28 on
    /// one with a notch, where the menu bar is outside the window
    /// (docs/testing.md).
    static let titleBarHeight: CGFloat = 72

    init(appPath: String) {
        self.appPath = appPath
        let layout = WrappLayout(app: URL(fileURLWithPath: appPath))
        let settings: WrappSettings?
        do {
            settings = try WrappSettings(of: layout)
            engineSetting = settings?.engine.rawValue ?? "unknown"
        } catch {
            settings = nil
            engineSetting = "unreadable (\(error.localizedDescription))"
        }
        composition = settings?.composition
        modules = TestModules(composition: composition, layout: layout, prefix: layout.prefix)
        gameSlug = settings?.gameSlug ?? "unknown"
        // The program its launch names, as the wrapp reads it.
        let launch = settings?.recordedLaunch
        // Steam's and Big Fish's launches name the program they start
        // (`--steam.exe`, `--big-fish.exe`).
        let exePath = launch.flatMap { launch in
            let program = launch.options["steam.exe"] ?? launch.options["big-fish.exe"] ?? launch.program
            return program.hasPrefix("wine:C:") ? String(program.dropFirst("wine:C:".count)) : nil
        }
            ?? settings?.gameExePath ?? "/Game.exe"
        gameExeName = (exePath as NSString).lastPathComponent
        winePrefix = layout.prefix
        graphics = composition?.has(.wine) == true
            ? GameGraphicsAPI(declared: launch?.options["wine.graphics"])
                ?? GameGraphicsAPI(exeAt: layout.onDriveC(exePath), game: GameInfoProvider.shared.gameInfo(for: gameSlug))
            : .unknown
    }
}

extension Wrapp {
    /// Commands that end the engine processes that can outlive the wrapp
    /// when WrappPuppeteer itself is stopped, from its signal handler, which
    /// can't wait to see whether anything ends more gently (`endEngine` does,
    /// otherwise; see `ProcessCleanup.install`): each module's own
    /// (`TestModule.cleanupCommands`). Only this wrapp's: the integration
    /// tests build other games beside a launch, and a machine-wide
    /// `pkill -f wine` once killed their installers and patchers.
    var cleanupCommands: [[String]] {
        modules.all.flatMap(\.cleanupCommands)
    }

    /// `pkill -9` of whatever runs from `path`, or nothing for a path that
    /// isn't inside an app bundle: a pattern that came out empty or short
    /// (as a failed substitution once made `pkill -f '^'`, which killed every
    /// process of the user's) must never reach pkill.
    static func pkillCommand(matchingFrom path: String) -> [[String]] {
        guard Self.isSafeToKill(from: path) else {
            Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.Wrapp")
                .error("Not killing processes by \"\(path)\": it isn't a path inside an app")
            return []
        }
        return [["/usr/bin/pkill", "-9", "-f", "^" + extendedRegexEscaped(path)]]
    }

    /// Whether `path` is specific enough to kill everything running from it:
    /// absolute, inside a `.app`, and longer than any path that could match
    /// unrelated processes.
    static func isSafeToKill(from path: String) -> Bool {
        path.hasPrefix("/") && path.contains(".app/") && path.count >= 20
    }

    /// End what the wrapp left of its engine once it has gone, firmly only if
    /// it won't end: a force-quit wrapp gets SIGTERM and ends its Wine itself,
    /// so this usually finds nothing; it matters when the wrapp had to be
    /// killed. Each module ends its own gently (`TestModule.endLeftovers`),
    /// last started first; then anything still running from the wrapp's own
    /// engines is killed. Only this wrapp's: other games may be building.
    func endEngine() {
        for module in modules.all.reversed() {
            guard let leftovers = module.endLeftovers(),
                  ProcessControl.anyRunning(matching: leftovers) else { continue }
            logger.warning("⚠️  The wrapp's engine is still running: killing it")
            if !ProcessControl.end(matching: leftovers, signal: SIGKILL, timeout: 3) {
                logger.error("❌ The wrapp's engine is still running after SIGKILL")
            }
        }
    }

    /// `text` as a POSIX extended regular expression (`pkill`'s) that
    /// matches only itself: a wrapp's name can hold `.`, `(` and the like.
    static func extendedRegexEscaped(_ text: String) -> String {
        let special: Set<Character> = [".", "[", "]", "(", ")", "*", "+", "?", "{", "}", "|", "^", "$", "\\"]
        return String(text.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }
}
