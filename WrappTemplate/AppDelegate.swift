//
//  AppDelegate.swift
//  WrappTemplate
//
//  The wrapp's application delegate: quitting, which ends the game and its
//  Wine session first, and opening the game again afterwards.

import Foundation
import AppKit
import Logging
import os
import SecondChanceKit
import SecondChanceReporting
import GameCatalog

// MARK: - Application Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app menu's Failure Reports…: what the shared settings are, and
    /// that Second Chance is where they change.
    @objc func showFailureReportSettings() {
        let preferences = ReportingPreferences.load()
        let level = preferences.level
        let alert = NSAlert()
        alert.messageText = String(localized: "Failure Reports")
        let current: String
        switch level {
        case .detailed: current = String(localized: "When the game fails to start, a detailed report is sent, with the log (your name and folders taken out).")
        case .basic: current = String(localized: "When the game fails to start, a basic report is sent: which game, and what failed.")
        case .manual: current = String(localized: "When the game fails to start, you're asked what to send.")
        }
        let success = preferences.successReports == true
            ? String(localized: "Success reports are on: Second Chance counts when a game starts, and whether it worked.")
            : String(localized: "Success reports are off.")
        let changing = String(localized: "You can change these in Second Chance → Settings. They apply to all your games.")
        alert.informativeText = [current, success, changing].joined(separator: "\n\n")
        alert.runModal()
    }

    let config: GameConfig
    let gameLauncher: GameLauncher?
    var isCleaningUp = false
    /// Set when the game crashes during loading, so quitting propagates the game's exit code.
    var gameExitCode: Int32 = 0
    /// Set when the player chose "Start Without Steam": once this launch is
    /// cleaned up, the wrapp opens again with `--launch-without-steam`.
    var relaunchWithoutSteam = false
    /// The player chose Try Again on a launch that seemed stuck, or the game
    /// had no display driver: once Wine has finished, a fresh copy starts,
    /// with these arguments.
    var tryAgain: [String]?
    /// The game has ended and the wrapp is closing down: waiting for Wine,
    /// hidden from the Dock. Set from the game's thread, read on main.
    private let closingState = OSAllocatedUnfairLock(initialState: (closing: false, openAgain: false))
    var isClosing: Bool {
        get { closingState.withLock { $0.closing } }
        set { closingState.withLock { $0.closing = newValue } }
    }
    /// Someone opened the game again while it was closing down: once Wine
    /// has finished, a fresh copy starts.
    var openAgainWhenClosed: Bool { closingState.withLock { $0.openAgain } }

    init(config: GameConfig, gameLauncher: GameLauncher?) {
        self.config = config
        self.gameLauncher = gameLauncher
        super.init()
    }

    /// Chosen in Cmd-Tab while the game runs: the game is in a process of
    /// its own, so the wrapp passes it on. Not while one of the
    /// wrapp's own windows is up (the log window, in debug mode), which the
    /// person may have clicked to get to.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isCleaningUp, !isClosing, !NSApp.windows.contains(where: { $0.isVisible }) else { return }
        _ = gameLauncher?.bringGameForward()
    }

    /// While the game runs, clicking the wrapp in the Dock brings the game,
    /// which runs in a process of its own, forward.
    ///
    /// Opening the game while this copy is closing down reaches this copy
    /// (macOS reactivates a running app rather than starting another), which
    /// would do nothing. Remember it, and start again once Wine has finished.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard isCleaningUp || isClosing else {
            guard gameLauncher?.hasGameWindow == true else { return true }
            // A click in the Dock sends the reopen before the wrapp is made
            // active, and only an active app can hand activation on: then
            // applicationDidBecomeActive, which follows, does it.
            if NSApp.isActive { _ = gameLauncher?.bringGameForward() }
            return false
        }
        mainLogger.notice("Opened again while the game is closing: it starts again once Wine has finished")
        closingState.withLock { $0.openAgain = true }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mainLogger.debug("[Cleanup/AppDelegate] applicationShouldTerminate called")

        // Quitting a launch that seems stuck: report it, then quit again.
        // Not on the way to relaunching without Steam, which isn't giving up.
        // Nor when the game had no display driver, already reported.
        if !isCleaningUp, !relaunchWithoutSteam, tryAgain != [WrappLaunchOptions.afterNoDisplayArgument],
           globalInfoWindow?.giveUpIfStuck() == true {
            mainLogger.notice("Quitting while the launch seems stuck: reporting it before quitting")
            return .terminateCancel
        }

        // Quitting with the first-failure question unanswered: send the
        // report basic, the error window saying so, then quit again.
        if !isCleaningUp, FailureReporter.sendUnansweredBeforeQuitting(then: {
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }) {
            return .terminateCancel
        }

        // Prevent multiple cleanup attempts
        guard !isCleaningUp else {
            mainLogger.debug("[Cleanup/AppDelegate] Already cleaning up, returning .terminateNow")
            return .terminateNow
        }

        mainLogger.debug("[Cleanup/AppDelegate] Setting isCleaningUp = true")
        isCleaningUp = true

        guard let gameLauncher = gameLauncher else {
            mainLogger.debug("[Cleanup/AppDelegate] No gameLauncher, returning .terminateNow")
            return .terminateNow
        }

        mainLogger.notice("[Cleanup/AppDelegate] Application terminating, performing cleanup...")

        // Perform cleanup and wait for completion
        mainLogger.debug("[Cleanup/AppDelegate] About to call gameLauncher.performCleanup...")
        gameLauncher.performCleanup {
            mainLogger.debug("[Cleanup/AppDelegate] Inside performCleanup completion handler")
            // Quitting from the error window: let its report finish going.
            FailureReporter.wait(for: gameLauncher.reportTask, timeout: 10)
            DispatchQueue.main.async {
                mainLogger.debug("[Cleanup/AppDelegate] On main queue, about to call NSApp.reply")
                mainLogger.notice("[Cleanup] All cleanup complete, terminating application")
                // Drain pending entries so the disk mirror / stderr keep the last lines.
                if self.relaunchWithoutSteam {
                    self.openAgain(arguments: [WrappLaunchOptions.withoutSteamArgument], why: "to start without Steam")
                } else if let arguments = self.tryAgain {
                    self.openAgain(arguments: arguments, why: "to try the launch again")
                } else if self.openAgainWhenClosed {
                    self.openAgain(arguments: [], why: "as it was opened while closing")
                }
                LogStore.shared.flush()
                if self.gameExitCode != 0 {
                    exit(self.gameExitCode)
                }
                NSApp.reply(toApplicationShouldTerminate: true)
                mainLogger.debug("[Cleanup/AppDelegate] NSApp.reply(toApplicationShouldTerminate: true) called")
            }
        }

        mainLogger.debug("[Cleanup/AppDelegate] Returning .terminateLater")
        // Return later - we'll call reply when cleanup is done
        return .terminateLater
    }

    /// Open a new instance of this wrapp, with `arguments`. Called once Steam
    /// and the Wine session have been stopped, so the new instance finds the
    /// prefix free. Through `open`, so it outlives us.
    func openAgain(arguments wrappArguments: [String], why: String) {
        // Marked, as this copy may not have quite gone when the new one looks
        // for another already running (`main`).
        var arguments = ["-n", config.appPath.path, "--args", WrappLaunchOptions.openedAgainArgument] + wrappArguments
        if CommandLine.arguments.contains("--debug") { arguments.append("--debug") }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = arguments
        do {
            try open.run()
            open.waitUntilExit()
            if open.terminationStatus == 0 {
                mainLogger.notice("[Cleanup] Opened \(config.gameTitle) again, \(why)")
            } else {
                mainLogger.error("[Cleanup] Couldn't open \(config.gameTitle) again (\(why)): open exited \(open.terminationStatus)")
            }
        } catch {
            mainLogger.error("[Cleanup] Couldn't open \(config.gameTitle) again (\(why)): \(error.localizedDescription)")
        }
    }
}
