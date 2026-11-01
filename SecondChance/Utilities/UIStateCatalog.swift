//
//  UIStateCatalog.swift
//  SecondChance
//
//  The states of Second Chance's main window that `sc screenshot app` draws
//  (`UIStateShots`). Add one for a screen or notice worth looking at without
//  making it happen for real. `welcome` is the README's picture.

import SecondChanceKit
import SwiftUI
import GameCatalog

@MainActor
enum UIStateCatalog {
    static var shots: [UIStateShot] {
        let size = ContentView.size
        func window(_ name: String, _ setUp: @escaping @MainActor (WrappBuildViewModel) -> Void) -> UIStateShot {
            UIStateShot(name, title: "Second Chance", width: size.width, height: size.height) {
                let viewModel = WrappBuildViewModel(bus: EventBus<AppEvent>())
                setUp(viewModel)
                return ContentView().environmentObject(viewModel)
            }
        }
        // A Steam build of Ghost Dogs, a minute and a quarter into signing in.
        func steam(_ substep: String, _ setUp: @escaping @MainActor (WrappBuildViewModel) -> Void = { _ in }) -> @MainActor (WrappBuildViewModel) -> Void {
            { viewModel in
                viewModel.selectedWrappSource = .steam
                viewModel.detectedGame = GameInfoProvider.shared.gameInfo(for: "ghost-dogs")
                viewModel.currentState = .installingGame(substep: substep, elapsedSeconds: 75)
                setUp(viewModel)
            }
        }
        let inAMinuteAndAHalf = Date().addingTimeInterval(100)
        return [
            window("welcome") { _ in },
            window("steam-starting", steam(SteamStartupStage.starting.message)),
            window("steam-updating", steam("Updating Steam") {
                $0.stepProgress = StepProgress(fraction: 0.42, text: "107 of 255 MB")
            }),
            window("steam-connecting", steam(SteamStartupStage.connecting.message)),
            window("steam-sign-in", steam("Waiting for you to sign in to Steam") {
                $0.instructions = SteamWrappBuilder.signInInstructions
            }),
            window("steam-slow", steam(SteamStartupStage.connecting.message) {
                $0.steamSignInNotice = .slow(restartAt: inAMinuteAndAHalf)
            }),
            window("steam-restarting", steam("Steam got stuck, so it's being started again")),
            window("steam-slow-again", steam(SteamStartupStage.connecting.message) {
                $0.steamSignInNotice = .slow(restartAt: nil)
            }),
            window("steam-stuck", steam(SteamStartupStage.connecting.message) {
                $0.steamSignInNotice = .stuck
            }),
            window("error-steam-stuck") {
                $0.selectedWrappSource = .steam
                $0.steamBuildCanRetry = true
                $0.currentState = .error(WrappBuildError.steamStoppedResponding.localizedDescription)
            },
            window("error-steam-sign-in-timed-out") {
                $0.selectedWrappSource = .steam
                $0.steamBuildCanRetry = true
                $0.currentState = .error(WrappBuildError.steamSignInTimedOut.localizedDescription)
            },
            window("completed") {
                $0.selectedWrappSource = .steam
                $0.detectedGame = GameInfoProvider.shared.gameInfo(for: "ghost-dogs")
                $0.currentState = .completed
            },
        ]
    }
}
