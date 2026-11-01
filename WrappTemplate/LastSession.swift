//
//  LastSession.swift
//  WrappTemplate
//
//  Waiting for the game's last session to finish before this one starts.

import Foundation
import AppKit
import Logging
import os
import SecondChanceKit
import SecondChanceReporting
import GameCatalog

// MARK: - The last session

/// Wine still running in the prefix is usually the game's last session, its
/// wrapp still waiting for it to close down, which takes seconds. Wait for it
/// in the loading window (`.lastSessionClosing`), which after a few seconds
/// also offers to stop it; if it closes before anyone answers, the offer goes
/// and the launch carries on to `nextStage`. Runs off the main thread, before
/// the game starts; "Quit" exits the wrapp, leaving it be.
func waitForLastSession(_ wine: Wine, infoWindow: InfoWindowController, then nextStage: LoadingStage) {
    let server = wine.server
    // Programs a killed session left behind never finish, and the game among
    // them would be taken for this launch's (`WineServer.clearLeftovers`).
    Blocking.wait { await server.clearLeftovers() }
    guard Blocking.wait({ await server.isRunning }) else { return }
    mainLogger.notice("Wine is still running in this game's prefix, probably from the last time it was played: waiting for it to finish")
    let started = Date()
    infoWindow.setStage(.lastSessionClosing)

    enum Outcome { case ended, choice(InfoWindowViewModel.LastSessionChoice) }
    let decided = DispatchSemaphore(value: 0)
    let outcome = OSAllocatedUnfairLock<Outcome?>(initialState: nil)
    let decide: @Sendable (Outcome) -> Void = { value in
        let first = outcome.withLock { current -> Bool in
            guard current == nil else { return false }
            current = value
            return true
        }
        if first { decided.signal() }
    }
    let waiter = server.onStop { decide(.ended) }
    DispatchQueue.main.async {
        infoWindow.onLastSessionChoice = { choice in decide(.choice(choice)) }
    }
    if waiter == nil, !Blocking.wait({ await server.isRunning }) { decide(.ended) }
    decided.wait()
    waiter?.terminate()
    DispatchQueue.main.async { infoWindow.onLastSessionChoice = nil }

    let waited = SubprocessWatch.duration(Date().timeIntervalSince(started))
    switch outcome.withLock({ $0 }) {
    case .ended, nil:
        mainLogger.notice("The last session's Wine finished after \(waited)")
    case .choice(.stopItAndContinue):
        mainLogger.notice("Player chose to stop the last session's Wine after \(waited)")
        let stopped = Blocking.wait {
            await server.stop()
            return await server.waitUntilStopped(timeout: 10)
        }
        if !stopped {
            mainLogger.warning("The last session's Wine was still running 10 s after it was stopped; starting anyway")
        }
    case .choice(.continueAnyway):
        mainLogger.notice("Player chose to start with the last session's Wine still running, after \(waited)")
    case .choice(.dontStart):
        mainLogger.notice("Player chose not to start the game while the last session's Wine is running")
        LogStore.shared.flush()
        exit(0)
    }
    infoWindow.setStage(nextStage)
}
