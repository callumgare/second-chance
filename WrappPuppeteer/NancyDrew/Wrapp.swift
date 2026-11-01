//
//  Wrapp.swift
//  WrappPuppeteer
//
//  What the Nancy Drew scenario needs to know about a Second Chance wrapp,
//  read from its AppSettings.plist, and how its engine behaves under test.

import Foundation
import GameCatalog
import SecondChanceKit
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.Wrapp")

struct Wrapp {
    let appPath: String
    /// The engine setting, for logging.
    let engineSetting: String
    /// The engine running the game; nil for a setting this doesn't know.
    let engine: GameInfo.GameEngine?
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
    var runsInWine: Bool { engine?.runsInWine ?? false }

    /// The process that owns the game's window. Wine runs the game's own
    /// `.exe`; ScummVM is a single native process.
    var gameProcessName: String { engine == .scummvm ? "scummvm" : gameExeName }

    /// ScummVM goes full screen without reliably becoming the active app, so
    /// it's judged by its window being fullscreen, and activating it would
    /// fight its own full-screen handling.
    var judgesFocusByFullscreen: Bool { engine == .scummvm }

    var activatesForFocus: Bool { engine != .scummvm }

    /// Whether the game starts through Steam, whose overlay shows a notice
    /// ("Press Shift+Tab to begin") in the window's bottom-right corner for
    /// a few seconds after it starts.
    var showsSteamOverlay: Bool { engine?.needsSteam ?? false }

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
        engine = settings?.engine
        gameSlug = settings?.gameSlug ?? "unknown"
        let exePath = settings?.gameExePath ?? "/Game.exe"
        gameExeName = (exePath as NSString).lastPathComponent
        winePrefix = layout.prefix
        graphics = engine?.runsInWine == true ? GameGraphicsAPI(exeAt: layout.onDriveC(exePath)) : .unknown
    }
}

extension Wrapp {
    /// Commands that end the engine processes that can outlive the wrapp
    /// when WrappPuppeteer itself is stopped, from its signal handler, which
    /// can't wait to see whether anything ends more gently (`endEngine` does,
    /// otherwise; see `ProcessCleanup.install`). Only this wrapp's: the integration
    /// tests build other games beside a launch, and a machine-wide
    /// `pkill -f wine` once killed their installers and patchers. For Wine,
    /// the wrapp's own `wineserver -k` ends everything in its prefix — Steam
    /// included — whatever it's called (under Wine 10 a Windows program's
    /// command line is its Windows path, `C:\Program Files (x86)\Steam\steam.exe`),
    /// then anything still running from the wrapp's own Wine. For ScummVM,
    /// the wrapp's own `scummvm`, by its path: by the time this runs the wrapp
    /// has gone and its child belongs to launchd.
    var cleanupCommands: [[String]] {
        let layout = WrappLayout(app: URL(fileURLWithPath: appPath))
        switch engine {
        case .wine, .wineSteam, .wineSteamSilent:
            let wineserver = layout.wine.appendingPathComponent("bin/wineserver").path
            return [["/usr/bin/env", "WINEPREFIX=\(winePrefix.path)", wineserver, "-k"]]
                + Self.pkillCommand(matchingFrom: layout.wine.path + "/")
        case .scummvm:
            return Self.pkillCommand(matchingFrom: layout.scummvm.path)
        case nil:
            return []
        }
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
    /// killed. Wine's session gets a few seconds to finish,
    /// then `wineserver -k`, then `-k9` (`WineServer.shutDown`); ScummVM gets
    /// SIGTERM before SIGKILL. Last, anything still running from the wrapp's
    /// own engine is killed. Only this wrapp's: other games may be building.
    func endEngine() {
        let layout = WrappLayout(app: URL(fileURLWithPath: appPath))
        let leftovers: String
        switch engine {
        case .wine, .wineSteam, .wineSteamSilent:
            let wine = Wine(wrapp: layout.app, prefix: winePrefix)
            if !Blocking.wait({ await wine.server.shutDown() }) {
                logger.error("❌ The wrapp's Wine session didn't end")
            }
            guard Self.isSafeToKill(from: layout.wine.path + "/") else { return }
            leftovers = "^" + Self.extendedRegexEscaped(layout.wine.path + "/")
        case .scummvm:
            guard Self.isSafeToKill(from: layout.scummvm.path) else { return }
            leftovers = "^" + Self.extendedRegexEscaped(layout.scummvm.path)
            if ProcessControl.anyRunning(matching: leftovers),
               ProcessControl.end(matching: leftovers, signal: SIGTERM, timeout: 5) {
                logger.notice("   ScummVM ended when asked")
                return
            }
        case nil:
            return
        }
        guard ProcessControl.anyRunning(matching: leftovers) else { return }
        logger.warning("⚠️  The wrapp's engine is still running: killing it")
        if !ProcessControl.end(matching: leftovers, signal: SIGKILL, timeout: 3) {
            logger.error("❌ The wrapp's engine is still running after SIGKILL")
        }
    }

    /// `text` as a POSIX extended regular expression (`pkill`'s) that
    /// matches only itself: a wrapp's name can hold `.`, `(` and the like.
    static func extendedRegexEscaped(_ text: String) -> String {
        let special: Set<Character> = [".", "[", "]", "(", ")", "*", "+", "?", "{", "}", "|", "^", "$", "\\"]
        return String(text.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }
}
