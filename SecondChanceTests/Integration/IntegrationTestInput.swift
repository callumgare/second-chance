//
//  IntegrationTestInput.swift
//  SecondChanceTests
//
//  A fixed-path WrappBuildInput for integration tests. Injected into
//  WrappBuildViewModel through its input factory, so a test drives the real
//  buildFrom* entry points with no global state involved.

import Foundation
@testable import SecondChance
import GameCatalog

@MainActor
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

    /// A headless input for a build from a Her Interactive download (`.exe`
    /// or `.dmg`).
    convenience init(
        herDownload: URL,
        outputDir: URL,
        viewModel: WrappBuildViewModel? = nil
    ) {
        self.init(environment: [
            "HER_INSTALLER_PATH": herDownload.path,
            "OUTPUT_PATH": outputDir.path,
        ], viewModel: viewModel)
    }

    /// A headless input for a build of a free game downloaded from where
    /// its bundle says (`program`: a bundle id).
    convenience init(
        download program: String,
        outputDir: URL,
        viewModel: WrappBuildViewModel? = nil
    ) {
        self.init(environment: [
            "DOWNLOAD_PROGRAM": program,
            "OUTPUT_PATH": outputDir.path,
        ], viewModel: viewModel)
    }

    /// A headless input for a Steam build of `slug`. Headless, so Steam can't
    /// ask anyone to sign in: the build needs a saved sign-in.
    convenience init(
        steamGame slug: String,
        launchMode: String? = nil,
        outputDir: URL,
        viewModel: WrappBuildViewModel? = nil
    ) {
        var environment = [
            "STEAM_GAME_SLUG": slug,
            "OUTPUT_PATH": outputDir.path,
        ]
        if let launchMode {
            environment["STEAM_LAUNCH_MODE"] = launchMode
        }
        self.init(environment: environment, viewModel: viewModel)
    }

    /// A headless input for a Big Fish build of `slug`: its free trial, or
    /// the full game, which signs in as the test harness
    /// (`BIG_FISH_TEST_SIGN_IN`) with the test account's `BIG_FISH_EMAIL` and
    /// `BIG_FISH_PASSWORD`, taken from the test's own environment (`sc`
    /// passes them from `.env`).
    convenience init(
        bigFishGame slug: String,
        trial: Bool,
        outputDir: URL,
        viewModel: WrappBuildViewModel? = nil
    ) {
        var environment = [
            "BIG_FISH_GAME_SLUG": slug,
            "OUTPUT_PATH": outputDir.path,
        ]
        if trial {
            environment["BIG_FISH_TRIAL"] = "1"
        } else {
            environment["BIG_FISH_TEST_SIGN_IN"] = "1"
            let own = ProcessInfo.processInfo.environment
            for name in ["BIG_FISH_EMAIL", "BIG_FISH_PASSWORD"] {
                environment[name] = own[name]
            }
        }
        self.init(environment: environment, viewModel: viewModel)
    }
}
