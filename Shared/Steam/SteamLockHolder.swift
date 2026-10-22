//
//  SteamLockHolder.swift
//  Shared
//
//  Whoever holds the one-Steam-at-a-time lock (`SteamActiveLock`), as the
//  person knows it — the game's name, not its bundle ID — and the way to quit
//  it for them when they ask: its own quit first, which stops its Steam and
//  saves the sign-in back, then harder, then its Wine session.

import AppKit
import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Steam")

nonisolated struct SteamLockHolder: Sendable, Equatable {
    /// What a build writes in the lock instead of a wrapp's bundle ID.
    static let buildBundleID = "Second Chance build"

    let pid: Int32?
    let bundleID: String?

    /// Second Chance building a game from Steam, not a wrapp playing one.
    var isBuild: Bool { bundleID == Self.buildBundleID }

    /// The running wrapp, when the lock's record still names it. A record
    /// whose process has become another app never matches.
    private var runningApp: NSRunningApplication? {
        guard let pid, let bundleID, !isBuild,
              let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier == bundleID else { return nil }
        return app
    }

    /// The name to show: the wrapp's (its game's title), or Second Chance for
    /// a build. Nil when the holder can't be found.
    var name: String? {
        if isBuild { return "Second Chance" }
        return runningApp?.localizedName
    }

    /// Whether `quit` can be offered: a wrapp that is still running. A build
    /// is never quit for someone — it is theirs to cancel.
    var canQuit: Bool { runningApp != nil }

    /// How long each way of quitting gets before the next, harder one.
    struct Patience: Sendable {
        /// The wrapp's own quit, which stops Steam (up to 10 s) and sends
        /// any failure report under way (up to 15 s).
        var quit: TimeInterval = 40
        /// SIGTERM, which the wrapp takes as a quit and ends itself 15 s on.
        var terminate: TimeInterval = 20
        var kill: TimeInterval = 5
    }

    /// Quit the wrapp, as Cmd-Q would; then SIGTERM; then SIGKILL — each
    /// once the one before has had its time. A wrapp that didn't quit itself
    /// leaves its Wine session (the game, Steam signed in) running, which
    /// would keep the account busy, so that is stopped too. Blocks; call it
    /// off the main thread. Returns whether the wrapp has gone.
    func quit(patience: Patience = Patience()) -> Bool {
        guard let app = runningApp, let pid else { return true }
        let name = app.localizedName ?? bundleID ?? "the wrapp"
        let appURL = app.bundleURL
        logger.notice("[Steam] Quitting \(name) (pid \(pid)), which holds Steam")

        app.terminate()
        if Self.waitForExit(of: pid, timeout: patience.quit) {
            logger.notice("[Steam] \(name) quit")
            return true
        }
        logger.warning("[Steam] \(name) didn't quit within \(Int(patience.quit))s; sending it SIGTERM")
        kill(pid, SIGTERM)
        var gone = Self.waitForExit(of: pid, timeout: patience.terminate)
        if !gone {
            logger.warning("[Steam] \(name) didn't end within \(Int(patience.terminate))s of SIGTERM; killing it")
            kill(pid, SIGKILL)
            gone = Self.waitForExit(of: pid, timeout: patience.kill)
        }
        if let appURL {
            let wine = WineEnvironment(appPath: appURL)
            if wine.isWineserverRunning() {
                logger.notice("[Steam] Stopping the Wine session \(name) left running")
                wine.stopWineserver()
            }
        }
        if !gone { logger.error("[Steam] \(name) (pid \(pid)) is still running after SIGKILL") }
        return gone
    }

    /// Wait for process `pid` — not a child of ours — to exit.
    static func waitForExit(of pid: Int32, timeout: TimeInterval) -> Bool {
        let exited = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { exited.signal() }
        source.resume()
        defer { source.cancel() }
        // Gone before the source was watching: it would never fire.
        if kill(pid, 0) != 0 && errno == ESRCH { return true }
        return exited.wait(timeout: .now() + timeout) == .success
    }

    // MARK: Asking

    enum Choice {
        case quitHolder
        case tryAgain
        case cancel
    }

    /// Ask what to do about the holder: quit it (saying plainly that the
    /// game loses anything unsaved), try again once they have quit it
    /// themselves, or give up. `blocked` says what is waiting, as the end of
    /// "Only one game can use Steam at a time, so …".
    @MainActor
    func ask(blocked: String) -> Choice {
        let (alert, choices) = alert(blocked: blocked)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : .cancel
    }

    /// The alert `ask` shows, and what each of its buttons chooses.
    @MainActor
    func alert(blocked: String) -> (NSAlert, [Choice]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if isBuild {
            alert.messageText = "Second Chance is adding a game from Steam"
            alert.informativeText = "Only one game can use Steam at a time, so \(blocked) Wait for Second Chance to finish, then try again."
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Cancel")
            return (alert, [.tryAgain, .cancel])
        }
        alert.messageText = "\(name ?? "Another game") is using Steam"
        alert.informativeText = "Only one game can use Steam at a time, so \(blocked)"
        if canQuit, let name {
            alert.informativeText += """
            \n\nSecond Chance can quit \(name) for you, but anything you haven't saved in it will be lost. \
            If you're partway through playing, save your game in \(name) and quit it yourself, then click Try Again.
            """
            // Try Again is the default: Return mustn't throw away a game.
            alert.addButton(withTitle: "Try Again")
            let quit = alert.addButton(withTitle: "Quit \(name)")
            quit.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            return (alert, [.tryAgain, .quitHolder, .cancel])
        }
        alert.informativeText += " Quit it, then click Try Again."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Cancel")
        return (alert, [.tryAgain, .cancel])
    }
}
