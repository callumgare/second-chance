//
//  BigFishGame.swift
//  SecondChanceKit
//
//  What Big Fish's Game Manager says about a game, and what it leaves on
//  disk once the game is installed. Pure, so it's unit-tested.

import Foundation
import GameCatalog

/// A game in the signed-in account's Big Fish library.
nonisolated public struct BigFishOwnedGame: Codable, Hashable, Sendable {
    public let sku: String
    public let title: String

    public init(sku: String, title: String) {
        self.sku = sku
        self.title = title
    }

    public var parsedSKU: BigFishSKU? { BigFishSKU(sku) }
}

/// Where the Game Manager has got to with one game, from its page's
/// `GM.data.installedGames[sku]`.
nonisolated public struct BigFishGameStatus: Codable, Equatable, Sendable {
    /// The Game Manager's state number (its page script names them only by
    /// how it draws them; docs/big-fish.md lists what each means).
    public let state: Int
    public let errorCode: Int
    public let downloadProgress: Double
    public let downloadSize: Double
    /// 0–100.
    public let installProgress: Double

    public init(state: Int, errorCode: Int = 0, downloadProgress: Double = 0, downloadSize: Double = 0, installProgress: Double = 0) {
        self.state = state
        self.errorCode = errorCode
        self.downloadProgress = downloadProgress
        self.downloadSize = downloadSize
        self.installProgress = installProgress
    }

    public enum Phase: Equatable, Sendable {
        /// Queued, paused, or between steps.
        case waiting
        /// 0–1, when the size is known.
        case downloading(Double?)
        case installing(Double?)
        /// Installed and activated: ready to play.
        case ready
        case downloadFailed
        case installFailed
        case activationFailed
        case failed
    }

    public var phase: Phase {
        switch state {
        case 5: .ready
        case 1, 16: .downloading(downloadSize > 0 ? min(1, downloadProgress / downloadSize) : nil)
        case 4, 6, 11: .installing(installProgress > 0 ? min(1, installProgress / 100) : nil)
        case 7, 13: .downloadFailed
        case 9: .installFailed
        case 8, 20: .activationFailed
        case 17, 21: .failed
        default: .waiting
        }
    }
}

/// A game the Game Manager installed: its folder holds the game, Big Fish's
/// launcher for it and `bfgstate.xml`, which says which is which.
nonisolated public struct BigFishInstalledGame: Equatable, Sendable {
    /// The game's folder, on the Mac.
    public let folder: URL
    public let sku: String
    /// Big Fish's DRM launcher (a random name such as `wqxgxgg.exe`): what the
    /// Game Manager runs to activate and start the game.
    public let launcher: String

    /// The message file Big Fish's own Play shortcut opens: `bfgprocess.exe`
    /// sends it to the DRM service, which starts the game.
    public var launchFile: URL { folder.appendingPathComponent("LaunchGame.bfg") }

    /// Reads `bfgstate.xml`'s `executablePath` (a Windows path) and
    /// `productID`. (Its `trialLength` is there for a bought game too.)
    public init?(folder: URL, stateXML: String) {
        func element(_ name: String) -> String? {
            guard let open = stateXML.range(of: "<\(name)>"),
                  let close = stateXML.range(of: "</\(name)>", range: open.upperBound..<stateXML.endIndex) else { return nil }
            return String(stateXML[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let sku = element("productID"), !sku.isEmpty,
              let path = element("executablePath"),
              let launcher = path.split(separator: "\\").last.map(String.init), !launcher.isEmpty else { return nil }
        self.folder = folder
        self.sku = sku
        self.launcher = launcher
    }

    /// The installed game in `programFiles` (the prefix's `Program Files (x86)`)
    /// for `sku`, found by the `bfgstate.xml` each Big Fish game has.
    public static func find(sku: BigFishSKU, in programFiles: URL) -> BigFishInstalledGame? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: programFiles, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let text = try? String(contentsOf: folder.appendingPathComponent("bfgstate.xml"), encoding: .utf8),
                  let game = BigFishInstalledGame(folder: folder, stateXML: text),
                  BigFishSKU(game.sku) == sku else { continue }
            return game
        }
        return nil
    }

    /// The program the game runs as, given the `.exe` files in its folder:
    /// the one `knownNames` (the catalog's names for it, from its disc or Steam
    /// release) has, or else the only one that isn't Big Fish's (the launcher,
    /// the uninstaller, DirectX's setup).
    public func gameExecutable(among files: [String], knownNames: [String]) -> String? {
        let exes = files.filter { $0.lowercased().hasSuffix(".exe") }
        for name in knownNames {
            if let match = exes.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return match }
        }
        let notBigFish: Set<String> = [launcher.lowercased(), "uninstall.exe", "dxwebsetup.exe", "dxsetup.exe"]
        let rest = exes.filter { !notBigFish.contains($0.lowercased()) }
        return rest.count == 1 ? rest[0] : nil
    }
}
