//
//  IntegrationTestInput.swift
//  SecondChanceTests
//
//  A headless WrappBuildInput for integration tests. Provides disk paths and
//  output dir directly (no env vars, no NSOpenPanel) and never calls exit().

import Foundation
@testable import SecondChance

/// A headless `WrappBuildInput` for integration tests. Injects fixed disk
/// paths and output directory via env-style overrides, never prompts the
/// user, and never calls `exit()`.
///
/// Works by supplying an in-memory "environment" to `WrappBuildInput` — every
/// lookup hits the env-var branch and no panel can ever appear.
final class IntegrationTestInput: WrappBuildInput, @unchecked Sendable {
    let disk1: URL
    let disk2: URL?
    let outputDir: URL

    var launchGameAfterBuild: Bool = false
    var onGameDetectedCallback: ((GameInfo) -> Void)?
    var onWrappBuildCompleteCallback: ((URL) -> Void)?

    init(disk1: URL, disk2: URL?, outputDir: URL) {
        self.disk1 = disk1
        self.disk2 = disk2
        self.outputDir = outputDir

        var env: [String: String] = [
            "DISK_1_PATH": disk1.path,
            "OUTPUT_PATH": outputDir.path,
        ]
        if let disk2 {
            env["DISK_2_PATH"] = disk2.path
        }

        super.init(environment: env, viewModel: nil)
    }

    // MARK: - Callback overrides

    override func onGameDetected(_ gameInfo: GameInfo) async {
        onGameDetectedCallback?(gameInfo)
    }

    override func onWrappBuildComplete(_ wrappPath: URL) async {
        onWrappBuildCompleteCallback?(wrappPath)
    }

    override func shouldLaunchGame() async -> (Bool, [String]) {
        return (launchGameAfterBuild, [])
    }
}
