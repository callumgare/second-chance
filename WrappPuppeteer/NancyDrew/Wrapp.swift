//
//  Wrapp.swift
//  WrappPuppeteer
//
//  What the Nancy Drew scenario needs to know about a Second Chance wrapp,
//  read from its AppSettings.plist, and how its engine behaves under test.

import Foundation
import GameCatalog
import SecondChanceKit

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
    /// (see `ProcessCleanup.install`). For Wine, first the wrapp's own
    /// `wineserver -k`, which ends everything in its prefix — Steam included —
    /// whatever it's called: under Wine 10 a Windows program's command line
    /// is its Windows path (`C:\Program Files (x86)\Steam\steam.exe`), which
    /// the old `pkill -f wine` never matched.
    var cleanupCommands: [[String]] {
        switch engine {
        case .wine, .wineSteam, .wineSteamSilent:
            let wineserver = WrappLayout(app: URL(fileURLWithPath: appPath)).wine.appendingPathComponent("bin/wineserver").path
            return [
                ["/usr/bin/env", "WINEPREFIX=\(winePrefix.path)", wineserver, "-k"],
                ["/usr/bin/pkill", "-9", "-f", "wine"],
            ]
        case .scummvm:
            return [["/usr/bin/pkill", "-9", "scummvm"]]
        case nil:
            return []
        }
    }
}
