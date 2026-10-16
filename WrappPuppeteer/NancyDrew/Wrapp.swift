//
//  Wrapp.swift
//  WrappPuppeteer
//
//  What the Nancy Drew scenario needs to know about a Second Chance wrapp,
//  read from its AppSettings.plist, and how its engine behaves under test.

import Foundation

/// The engine running the game inside a wrapp. Maps the wrapp's `GameEngine`
/// setting (`wine`, `wineSteam`, `wineSteamSilent`, `scummvm`) to the
/// behaviour that matters when driving it.
enum WrappEngine {
    case wine
    case scummvm
    case other

    init(settingValue: String?) {
        let value = settingValue?.lowercased() ?? ""
        if value.contains("wine") {
            self = .wine
        } else if value.contains("scummvm") {
            self = .scummvm
        } else {
            self = .other
        }
    }

    /// The process that owns the game's window. Wine runs the game's own
    /// `.exe`; ScummVM is a single native process.
    func gameProcessName(gameExeName: String) -> String {
        self == .scummvm ? "scummvm" : gameExeName
    }

    /// Engine processes that can outlive the wrapp and must be killed with it.
    var helperPkillArguments: [[String]] {
        switch self {
        case .wine: return [["-9", "-f", "wine"]]
        case .scummvm: return [["-9", "scummvm"]]
        case .other: return []
        }
    }

    /// ScummVM goes full screen without reliably becoming the active app, so
    /// it's judged by its window, and activating it would fight its own
    /// full-screen handling.
    var focusStrategy: FocusStrategy {
        self == .scummvm ? .fullscreenWindow : .frontmost
    }

    var activatesForFocus: Bool { self != .scummvm }
}

struct Wrapp {
    let appPath: String
    /// The raw `GameEngine` setting, for logging.
    let engineSetting: String
    let engine: WrappEngine
    let gameExeName: String
    let winePrefix: URL

    init(appPath: String) {
        self.appPath = appPath
        let settings = Wrapp.readSettings(appPath: appPath)
        engineSetting = settings["GameEngine"] as? String ?? "unknown"
        engine = WrappEngine(settingValue: engineSetting)
        let exePath = settings["GameExePath"] as? String ?? "/Game.exe"
        gameExeName = (exePath as NSString).lastPathComponent
        winePrefix = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/SharedSupport/prefix")
    }

    private static func readSettings(appPath: String) -> [String: Any] {
        let url = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Resources/AppSettings.plist")
        do {
            let data = try Data(contentsOf: url)
            return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        } catch {
            return [:]
        }
    }
}
