//
//  IntegrationTestContext.swift
//  SecondChanceTests
//
//  An InstallationContext for integration tests. Provides disk paths and output
//  dir directly (no env vars, no NSOpenPanel) and never calls exit().

import Foundation
@testable import SecondChance

/// An `InstallationContext` for integration tests. Injects fixed disk paths and
/// output directory, never prompts the user, and never calls `exit()`.
final class IntegrationTestContext: InstallationContext, @unchecked Sendable {
    let disk1: URL
    let disk2: URL?
    let outputDir: URL

    var launchAfterInstall: Bool = false
    var onGameDetectedCallback: ((GameInfo) -> Void)?
    var onInstallationCompleteCallback: ((URL) -> Void)?

    init(disk1: URL, disk2: URL?, outputDir: URL) {
        self.disk1 = disk1
        self.disk2 = disk2
        self.outputDir = outputDir
    }

    // MARK: - InstallationContext

    func getDisk1Path() async throws -> URL {
        return disk1
    }

    func getDisk2Path(gameInfo: GameInfo) async throws -> URL? {
        // Return the injected disk2 if provided, regardless of diskCount.
        // Tests set this up correctly based on the game's diskCount.
        return disk2
    }

    func getOutputPath(gameName: String) async throws -> URL {
        // Create the output directory if it doesn't exist.
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        return outputDir
    }

    func onGameDetected(_ gameInfo: GameInfo) async {
        onGameDetectedCallback?(gameInfo)
    }

    func onInstallationComplete(_ wrapperPath: URL) async {
        onInstallationCompleteCallback?(wrapperPath)
    }

    func shouldLaunchGame() async -> (Bool, [String]) {
        return (launchAfterInstall, [])
    }

    func requestVolumeAccess(mountPoint: URL) async throws -> URL {
        // Tests don't need volume access prompts.
        return mountPoint
    }
}
