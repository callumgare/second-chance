//
//  IconLabHost.swift
//  SecondChance
//
//  Icon Lab's engine for the app (Debug ▸ Icon Lab…): one for the app's
//  life, made the first time the window opens. The window's web view
//  reaches it only through `IconLabAPI.handle`, so every request is
//  answered off the main actor (Packages/IconLab/README.md).

import Foundation
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
    /// The standalone lab's data, which the window offers to move in (`IconLabMigration`).
    var oldData: URL?

    init(data: URL, env: URL? = nil, tools: LabTools = LabTools(), oldData: URL? = nil) {
        self.data = data
        self.env = env
        self.tools = tools
        self.oldData = oldData
    }

    /// `<Application Support>/SecondChance/Icon Lab`, beside the app's other folders.
    /// `SECOND_CHANCE_ICON_LAB_DATA` names another.
    static func dataFolder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["SECOND_CHANCE_ICON_LAB_DATA"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return StoreLocations.realAppSupport.appendingPathComponent("SecondChance/Icon Lab", isDirectory: true)
    }

    /// This build's: in a Debug build, the checkout it was built from gives the keys (its `.env`), `icon-extract`
    /// (built in its WrappKit package), `built-apps/` and the old data; in any build, Xcode's `ictool` if it's there.
    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> IconLabPaths {
        var tools = LabTools(ictool: FileManager.default.isExecutableFile(atPath: LabTools.xcodeICTool) ? LabTools.xcodeICTool : nil)
        var env: URL?
        var oldData: URL?
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "icon-extract") { tools.iconExtract = bundled.path }
        if let checkout = sourceCheckout {
            let inCheckout = LabTools.inCheckout(checkout)
            tools.iconExtract = tools.iconExtract ?? inCheckout.iconExtract
            tools.builtApps = inCheckout.builtApps
            env = checkout.appendingPathComponent(".env")
            oldData = checkout.appendingPathComponent(".local/tools/icon-lab/data", isDirectory: true)
        }
        if let path = environment["SECOND_CHANCE_ICON_LAB_OLD_DATA"], !path.isEmpty { oldData = URL(fileURLWithPath: path, isDirectory: true) }
        return IconLabPaths(data: dataFolder(environment: environment), env: env, tools: tools, oldData: oldData)
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
        let api = IconLabAPI(dataDir: paths.data, env: Env(file: paths.env), tools: paths.tools)
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
