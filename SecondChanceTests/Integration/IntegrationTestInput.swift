//
//  IntegrationTestInput.swift
//  SecondChanceTests
//
//  A fixed-path WrappBuildInput for integration tests. Injected into
//  WrappBuildViewModel through its input factory, so a test drives the real
//  buildFrom* entry points with no global state involved.

import Foundation
@testable import SecondChance

extension WrappBuildInput {
    /// A headless input carrying fixed paths.
    ///
    /// Works by handing `WrappBuildInput` an in-memory "environment": every
    /// lookup takes the env-var branch, so no `NSOpenPanel` can ever appear
    /// and no real process environment variable has to be set. Nothing here
    /// terminates the process.
    ///
    /// Pass `viewModel` when driving a build through `WrappBuildViewModel` so
    /// `onGameDetected` still reaches the UI state.
    convenience init(
        disk1: URL,
        disk2: URL? = nil,
        outputDir: URL,
        launchGame: Bool = false,
        viewModel: WrappBuildViewModel? = nil
    ) {
        var environment = [
            "DISK_1_PATH": disk1.path,
            "OUTPUT_PATH": outputDir.path,
        ]
        if let disk2 {
            environment["DISK_2_PATH"] = disk2.path
        }
        if launchGame {
            environment["LAUNCH_GAME"] = "true"
        }
        self.init(environment: environment, viewModel: viewModel)
    }
}
