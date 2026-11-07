//
//  IconLabHost.swift
//  SecondChance
//
//  Icon Lab's engine for the app (Debug ▸ Icon Lab…): one for the app's
//  life, made the first time the window opens. The window's web view
//  reaches it only through `IconLabAPI.handle`, so every request is
//  answered off the main actor (Packages/IconLab/README.md).

import Foundation
import GameCatalog
import IconLabAPI
import IconLabKit
import Logging
import SecondChanceKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab")

/// Where Icon Lab keeps its data, its keys and the tools it uses.
nonisolated struct IconLabPaths: Sendable {
    /// Everything Icon Lab keeps: programs, caches, catalogue copies, models.
    var data: URL
    /// The `.env` its keys come from, if any.
    var env: URL?
    var tools: LabTools
    /// The programs Second Chance has bundles for, and the checkout's `Bundles/` to save designs to.
    var host: LabHostInfo
    /// The standalone lab's data, which the window offers to move in (`IconLabMigration`).
    var oldData: URL?

    init(data: URL, env: URL? = nil, tools: LabTools = LabTools(), host: LabHostInfo = LabHostInfo(), oldData: URL? = nil) {
        self.data = data
        self.env = env
        self.tools = tools
        self.host = host
        self.oldData = oldData
    }

    /// `<Application Support>/SecondChance/Icon Lab`, beside the app's other folders.
    /// `SECOND_CHANCE_ICON_LAB_DATA` names another.
    static func dataFolder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["SECOND_CHANCE_ICON_LAB_DATA"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return StoreLocations.realAppSupport.appendingPathComponent("SecondChance/Icon Lab", isDirectory: true)
    }

    /// This build's: the programs Second Chance has bundles for, and Xcode's `ictool` if it's there; in a Debug
    /// build, the checkout it was built from also gives the keys (its `.env`), `built-apps/`, `Bundles/` (to save
    /// designs to) and the old data. `SECOND_CHANCE_ICON_LAB_BUNDLES` and `SECOND_CHANCE_ICON_LAB_OLD_DATA` name others.
    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> IconLabPaths {
        var tools = LabTools(ictool: LabTools.installedICTool)
        var host = LabHostInfo(knownPrograms: knownPrograms())
        var env: URL?
        var oldData: URL?
        if let checkout = sourceCheckout {
            tools.builtApps = LabTools.inCheckout(checkout).builtApps
            host.bundles = checkout.appendingPathComponent("Bundles", isDirectory: true)
            env = checkout.appendingPathComponent(".env")
            oldData = checkout.appendingPathComponent(".local/tools/icon-lab/data", isDirectory: true)
        }
        if let path = environment["SECOND_CHANCE_ICON_LAB_BUNDLES"], !path.isEmpty { host.bundles = URL(fileURLWithPath: path, isDirectory: true) }
        if let path = environment["SECOND_CHANCE_ICON_LAB_OLD_DATA"], !path.isEmpty { oldData = URL(fileURLWithPath: path, isDirectory: true) }
        return IconLabPaths(data: dataFolder(environment: environment), env: env, tools: tools, host: host, oldData: oldData)
    }

    /// Every program in the game catalogue (the shipped bundles, and the extra ones `sc --bundle` named), once each.
    static func knownPrograms(_ catalogue: GameInfoProvider = .shared) -> [KnownProgram] {
        var seen: Set<String> = []
        return catalogue.allGames().compactMap { game in
            guard seen.insert(game.programID).inserted else { return nil }
            return KnownProgram(id: game.programID, title: game.appName)
        }
    }

    /// The checkout a Debug build was built from (`SourceCheckout` in its Info.plist, from `$(SRCROOT)`); nil in a
    /// Release build, which records none.
    static var sourceCheckout: URL? {
        #if DEBUG
        guard let path = Bundle.main.object(forInfoDictionaryKey: "SourceCheckout") as? String, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
        #else
        return nil
        #endif
    }
}

/// The engine the Icon Lab window talks to.
final class IconLabHost {
    static let shared = IconLabHost(paths: .current())

    let paths: IconLabPaths
    private var made: IconLabAPI?
    private var started = false

    init(paths: IconLabPaths) {
        self.paths = paths
    }

    /// Whether the engine has been made (it then owns the data folder, so nothing is moved into it).
    var isRunning: Bool { made != nil }

    /// The API, made the first time it's asked for.
    var api: IconLabAPI {
        if let made { return made }
        logger.notice("Icon Lab's data: \(paths.data.path)")
        let api = IconLabAPI(dataDir: paths.data, env: Env(file: paths.env), tools: paths.tools, host: paths.host)
        made = api
        return api
    }

    /// The engine's start-up work, once: analysis of what hasn't been, the catalogue's local copies, duplicates and
    /// the models' events. The first lab's games aren't imported here.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        let api = api
        Task.detached { await api.start(importingV1From: nil, refreshingLocalCopies: true) }
    }
}
