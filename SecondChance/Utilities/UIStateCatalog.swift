//
//  UIStateCatalog.swift
//  SecondChance
//
//  The states of Second Chance's main window that `sc screenshot app` draws
//  (`UIStateShots`). Add one for a screen or notice worth looking at without
//  making it happen for real. `welcome` is the README's picture.

import SecondChanceKit
import SecondChanceReporting
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
                return ContentView().environment(viewModel)
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
        // A Big Fish build of The White Wolf of Icicle Creek.
        func bigFish(_ substep: String, _ setUp: @escaping @MainActor (WrappBuildViewModel) -> Void = { _ in }) -> @MainActor (WrappBuildViewModel) -> Void {
            { viewModel in
                viewModel.selectedWrappSource = .bigFish
                viewModel.detectedGame = GameInfoProvider.shared.gameInfo(for: "white-wolf")
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
            window("big-fish-sign-in", bigFish(String(localized: "Waiting for you to sign in to Big Fish Games")) {
                $0.instructions = BigFishWrappBuilder.signInInstructions
            }),
            window("steam-which-game", steam(String(localized: "Checking which games your Steam account owns")) {
                $0.detectedGame = nil
                $0.question = WrappBuildViewModel.BuildQuestion(
                    title: String(localized: "Which game do you want from Steam?"),
                    detail: String(localized: "These are the Nancy Drew games your Steam account owns. Second Chance installs the one you pick through Steam."),
                    choicesLabel: String(localized: "Games"),
                    choices: ["ghost-dogs", "haunted-carousel", "deception-island", "shadow-ranch", "blackmoor-manor"]
                        .map { .init(title: GameInfoProvider.shared.gameInfo(for: $0).title) })
            }),
            window("steam-launch-mode", steam(String(localized: "Checking which games your Steam account owns")) {
                $0.question = WrappBuildViewModel.BuildQuestion(
                    title: String(localized: "How should \(GameInfoProvider.shared.gameInfo(for: "ghost-dogs").title) start?"),
                    detail: String(localized: "Either way it's the same game. They differ in how quickly it starts and where your saves are kept."),
                    choicesLabel: String(localized: "Ways to start the game"),
                    choices: [
                        .init(title: String(localized: "Launch Directly"),
                              detail: String(localized: "Starts faster and is more reliable, but saves stay on this Mac.")),
                        .init(title: String(localized: "Launch via Steam"),
                              detail: String(localized: "Keeps your saves in Steam Cloud, but starts slower.")),
                    ])
            }),
            window("big-fish-downloading", bigFish(String(localized: "Downloading the game")) {
                $0.stepProgress = StepProgress(fraction: 0.42, text: "42% done")
            }),
            window("error-steam-stuck") {
                $0.selectedWrappSource = .steam
                $0.currentState = .error(WrappBuildError.steamStoppedResponding.playerMessage)
            },
            window("error-steam-sign-in-timed-out") {
                $0.selectedWrappSource = .steam
                $0.currentState = .error(WrappBuildError.steamSignInTimedOut.playerMessage)
            },
            // The first failure anywhere: its report asks how detailed to send it.
            window("error-first-failure") {
                $0.selectedWrappSource = .disk
                $0.currentState = .error(WrappBuildError.installStalled.playerMessage)
                $0.failureReport.track(FailureReport(what: "Building the wrapp", kind: "WrappBuildError.installStalled"),
                                       sending: Task { .askingHowDetailed })
            },
            // Show What's Sent…, with made-up values.
            UIStateShot("report-preview-basic", title: "What's Sent in a Report",
                        width: ReportPreviewSample.size.width, height: ReportPreviewSample.size.height) {
                ReportPreviewSample.view(detail: .basic)
            },
            UIStateShot("report-preview-detailed", title: "What's Sent in a Report",
                        width: ReportPreviewSample.size.width, height: ReportPreviewSample.size.height) {
                ReportPreviewSample.view(detail: .detailed)
            },
            UIStateShot("report-preview-log", title: "What's Sent in a Report",
                        width: ReportPreviewSample.size.width, height: ReportPreviewSample.size.height) {
                ReportPreviewSample.view(detail: .detailed, file: "log.txt")
            },
            window("completed") {
                $0.selectedWrappSource = .steam
                $0.detectedGame = GameInfoProvider.shared.gameInfo(for: "ghost-dogs")
                $0.currentState = .completed
            },
        ]
    }
}
