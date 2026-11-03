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

nonisolated public struct SteamLockHolder: Sendable, Equatable {
    /// What a build writes in the lock instead of a wrapp's bundle ID.
    public static let buildBundleID = "Second Chance build"

    public let pid: Int32?
    public let bundleID: String?

    /// Second Chance building a game from Steam, not a wrapp playing one.
    public var isBuild: Bool { bundleID == Self.buildBundleID }

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
    public var name: String? {
        if isBuild { return "Second Chance" }
        return runningApp?.localizedName
    }

    /// A name as alerts and screens show it, in quotes as macOS's own alerts
    /// quote app names: a game's title has dashes and colons of its own.
    public static func quoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }

    /// Whether `quit` can be offered: a wrapp that is still running. A build
    /// is never quit for someone — it is theirs to cancel.
    public var canQuit: Bool { runningApp != nil }

    /// How long each way of quitting gets before the next, harder one.
    public struct Patience: Sendable {
        /// The wrapp's own quit, which stops Steam (up to 10 s) and sends
        /// any failure report under way (up to 15 s).
        var quit: TimeInterval = 40
        /// SIGTERM, which the wrapp takes as a quit and ends itself 15 s on.
        var terminate: TimeInterval = 20
        var kill: TimeInterval = 5

        public init() {}
    }

    /// Quit the wrapp, as Cmd-Q would; then SIGTERM; then SIGKILL — each
    /// once the one before has had its time. A wrapp that didn't quit itself
    /// leaves its Wine session (the game, Steam signed in) running, which
    /// would keep the account busy, so that is stopped too. The waits for
    /// it to exit run on a GCD thread (`Blocking.run`). Returns whether the
    /// wrapp has gone.
    public func quit(patience: Patience = Patience()) async -> Bool {
        guard let app = runningApp, let pid else { return true }
        let name = app.localizedName ?? bundleID ?? "the wrapp"
        let appURL = app.bundleURL
        logger.notice("[Steam] Quitting \(name) (pid \(pid)), which holds Steam")

        app.terminate()
        if await Blocking.run({ Self.waitForExit(of: pid, timeout: patience.quit) }) {
            logger.notice("[Steam] \(name) quit")
            return true
        }
        logger.warning("[Steam] \(name) didn't quit within \(Int(patience.quit))s; sending it SIGTERM")
        kill(pid, SIGTERM)
        var gone = await Blocking.run { Self.waitForExit(of: pid, timeout: patience.terminate) }
        if !gone {
            logger.warning("[Steam] \(name) didn't end within \(Int(patience.terminate))s of SIGTERM; killing it")
            kill(pid, SIGKILL)
            gone = await Blocking.run { Self.waitForExit(of: pid, timeout: patience.kill) }
        }
        if let appURL {
            for wine in Self.wines(of: appURL, bundleID: bundleID) {
                let server = wine.server
                if await server.isRunning {
                    logger.notice("[Steam] Stopping the Wine session \(name) left running in \(wine.prefix.path)")
                    await server.stop()
                }
            }
        }
        if !gone { logger.error("[Steam] \(name) (pid \(pid)) is still running after SIGKILL") }
        return gone
    }

    /// Where a wrapp's Wine session may be: in its own prefix, or — when that
    /// is read-only, as on a disk image — in the copy it makes in Caches
    /// (`getWinePrefix`), when there is one.
    static func wines(of appURL: URL, bundleID: String?,
                      caches: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first) -> [Wine] {
        var wines = [Wine(wrapp: appURL)]
        if let bundleID, let caches {
            let copy = caches.appendingPathComponent(bundleID).appendingPathComponent("prefix")
            if FileManager.default.fileExists(atPath: copy.path) {
                wines.append(Wine(wrapp: appURL, prefix: copy))
            }
        }
        return wines
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

    public enum Choice: Sendable {
        case quitHolder
        case tryAgain
        case cancel
    }

    /// Ask what to do about the holder: try again once they have saved and
    /// quit it themselves, give up, or — the fallback, saying plainly that
    /// the game loses anything unsaved — have it quit for them. `blocked` says what is waiting, as the end of
    /// "Only one game can use Steam at a time, so …".
    @MainActor
    public func ask(blocked: String) -> Choice {
        let (alert, choices) = alert(blocked: blocked)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : .cancel
    }

    /// What `ask` asks: a title, the explanation, and a button for each
    /// choice. A build shows it as a page of Second Chance's window, and
    /// a game's app as an alert.
    public struct Prompt {
        public struct Button {
            public let title: String
            public let choice: Choice
            /// It loses something: a game quit without saving.
            public let destructive: Bool
        }
        public let title: String
        public let detail: String
        /// In order: Try Again first, as the way on.
        public let buttons: [Button]
    }

    /// What to ask about the holder.
    ///
    /// `blocked` is a whole sentence saying what is waiting: "Old Clock
    /// can't start until it quits." The text is whole sentences either side
    /// of it, so each can be translated as one.
    public func prompt(blocked: String) -> Prompt {
        let oneAtATime = String(localized: "Only one game can use Steam at a time.")
        let tryAgain = Prompt.Button(title: String(localized: "Try Again"), choice: .tryAgain, destructive: false)
        let cancel = Prompt.Button(title: String(localized: "Cancel"), choice: .cancel, destructive: false)
        if isBuild {
            return Prompt(title: String(localized: "Second Chance is adding a game from Steam"),
                          detail: [oneAtATime, blocked, String(localized: "Wait for Second Chance to finish, then try again.")]
                              .joined(separator: " "),
                          buttons: [tryAgain, cancel])
        }
        let title = name.map(Self.quoted).map { String(localized: "\($0) is using Steam") }
            ?? String(localized: "Another game is using Steam")
        if canQuit, let name = name.map(Self.quoted) {
            // Quitting it themselves comes first: they can save before it
            // goes. Having it quit for them is the fallback, offered last.
            let detail = [oneAtATime, blocked, String(localized: "Save your game in \(name) and quit it, then click Try Again.")]
                .joined(separator: " ") + "\n\n"
                + String(localized: "If \(name) won't quit, Second Chance can quit it for you, but anything you haven't saved in it will be lost.")
            let quit = Prompt.Button(title: String(localized: "Quit It Without Saving"), choice: .quitHolder, destructive: true)
            return Prompt(title: title, detail: detail, buttons: [tryAgain, cancel, quit])
        }
        return Prompt(title: title,
                      detail: [oneAtATime, blocked, String(localized: "Quit it, then click Try Again.")].joined(separator: " "),
                      buttons: [tryAgain, cancel])
    }

    /// The alert `ask` shows, and what each of its buttons chooses.
    @MainActor
    func alert(blocked: String) -> (NSAlert, [Choice]) {
        let prompt = prompt(blocked: blocked)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.detail
        for button in prompt.buttons {
            // Destructive, as macOS marks a button that loses work. It's the
            // only warning style an alert button takes: macOS 26 ignores a
            // red title (`contentTintColor`, `attributedTitle`).
            alert.addButton(withTitle: button.title).hasDestructiveAction = button.destructive
        }
        return (alert, prompt.buttons.map(\.choice))
    }
}
