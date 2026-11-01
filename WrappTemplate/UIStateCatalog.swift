//
//  UIStateCatalog.swift
//  WrappTemplate
//
//  The states of a wrapp's loading window that `sc screenshot wrapp` draws
//  (`UIStateShots`). Add one for a screen or notice worth looking at
//  without making it happen for real.

import SecondChanceKit
import SwiftUI

@MainActor
enum UIStateCatalog {
    static var shots: [UIStateShot] {
        // `setUp` runs before the window appears and again after, since the
        // window resets its notes as its stage's clock starts.
        func window(_ name: String, _ stage: LoadingStage, title: String = "Stay Tuned for Danger", warning: Bool = false,
                    _ setUp: @escaping @MainActor (InfoWindowViewModel) -> Void = { _ in }) -> UIStateShot {
            let viewModel = InfoWindowViewModel(stage: stage, saveWarningEnabled: warning, gameTitle: title)
            setUp(viewModel)
            return UIStateShot(name, title: title, style: [.titled], width: InfoWindowView.width, afterAppearing: {
                viewModel.stopTimer()
                setUp(viewModel)
            }, view: {
                InfoWindowView(viewModel: viewModel)
            })
        }
        let steamGame = "Ghost Dogs of Moon Lake"
        let busyMac = SystemLoadReading(otherCores: 7.4, fastCores: 8,
                                        topPrograms: [.init(name: "Google Chrome", cores: 4), .init(name: "node", cores: 2)])
        let newer = ReleaseVersion(shortVersion: "9.9.0", build: 9999)
        let inAMinuteAndAHalf = Date().addingTimeInterval(100)
        return [
            window("save-warning", .startingGame(title: "Stay Tuned for Danger"), warning: true),
            window("starting-game", .startingGame(title: "Stay Tuned for Danger")),
            window("starting-game-slow", .startingGame(title: "Stay Tuned for Danger")) { $0.showSlowLoadingNote = true },
            window("heavy-load", .startingGame(title: "Stay Tuned for Danger")) { $0.heavyLoad = busyMac },
            window("possible-launch-failure", .startingGame(title: "Stay Tuned for Danger")) { $0.showSuspectedHang = true },
            window("possible-launch-failure-steam", .steamStartingGame(title: "Danger on Deception Island"), title: "Danger on Deception Island") {
                $0.onLaunchWithoutSteam = {}
                $0.showSuspectedHang = true
            },
            window("last-session-closing", .lastSessionClosing) { $0.showSuspectedHang = true },
            window("steam-starting", .startingSteam, title: steamGame),
            window("steam-updating", .updatingSteam(.downloading(doneKB: 109_568, totalKB: 261_120)), title: steamGame),
            window("steam-connecting", .connectingToSteam, title: steamGame),
            window("steam-sign-in", .signingInToSteam, title: steamGame),
            window("steam-slow", .connectingToSteam, title: steamGame) { $0.steamNotice = .slow(restartAt: inAMinuteAndAHalf) },
            window("steam-restarting", .startingSteam, title: steamGame),
            window("steam-slow-again", .connectingToSteam, title: steamGame) { $0.steamNotice = .slow(restartAt: nil) },
            window("steam-stuck", .connectingToSteam, title: steamGame) {
                $0.steamNotice = .stuck
                $0.onSignInToSteamAfresh = {}
            },
            window("steam-starting-game", .steamStartingGame(title: steamGame), title: steamGame),
            window("error-crashed", .startingGame(title: "Stay Tuned for Danger")) {
                $0.phase = .error(exitCode: 1, explanation: nil)
                $0.newerRelease = newer
            },
            window("error-quit-unexpectedly", .startingGame(title: "The White Wolf of Icicle Creek"), title: "The White Wolf of Icicle Creek") {
                $0.phase = .error(exitCode: 0, explanation: "The game asked for a display mode this Mac doesn't have, and quit when it couldn't have it.")
            },
            window("gave-up", .startingGame(title: "Stay Tuned for Danger")) { $0.phase = .gaveUp },
            window("quitting", .startingGame(title: "Stay Tuned for Danger")) { $0.phase = .quitting(.closing) },
            window("quitting-steam", .startingGame(title: steamGame), title: steamGame) { $0.phase = .quitting(.closingSteam) },
            window("quitting-stopping", .startingGame(title: "Stay Tuned for Danger")) { $0.phase = .quitting(.stopping) },
            window("quitting-forcing", .startingGame(title: "Stay Tuned for Danger")) { $0.phase = .quitting(.forcing) },
        ]
    }
}
