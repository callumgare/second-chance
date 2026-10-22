//
//  SteamLogs.swift
//  Shared
//
//  Reading Steam's own logs (Steam/logs/) for what it doesn't say anywhere
//  else: whether it signed in, and what an install is doing. Neither its
//  files nor its registry values say either reliably — an appmanifest's
//  byte counts stay 0 until the download is over — so the logs are it.

import Foundation

nonisolated enum SteamLogs {
    /// Where a sign-in has got to, from `logs/connection_log.txt` and
    /// `logs/steamui_login.txt`.
    enum LoginState: Equatable, Sendable {
        /// Steam is still starting or connecting.
        case pending
        /// Signed in: `RecvMsgClientLogOnResponse() : … 'OK'`.
        case signedIn
        /// Showing the sign-in window: no session, or a rejected one
        /// (`Invalid Password` when the stored token no longer works).
        case needsCredentials(reason: String?)
    }

    /// The login state from the text Steam appended to the two logs since it
    /// started. Pass only the new text: both logs keep earlier sessions.
    static func loginState(connectionLog: String, loginLog: String) -> LoginState {
        // Steam can fail a logon and then succeed on retry, so the last word wins.
        var state = LoginState.pending
        for line in (connectionLog + "\n" + loginLog).split(whereSeparator: \.isNewline) {
            if line.contains("RecvMsgClientLogOnResponse()"), line.contains("'OK'") {
                state = .signedIn
            } else if line.contains("Received logon success response") {
                state = .signedIn
            } else if let range = line.range(of: "SetLoginState: WaitingForCredentials") {
                let rest = line[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " -"))
                state = .needsCredentials(reason: rest.isEmpty || rest == "OK" ? nil : rest)
            }
        }
        return state
    }

    /// Whether the client has started connecting to Steam's servers but not
    /// yet signed in, from `logs/connection_log.txt`: its lines carry the
    /// connection's state,
    ///
    ///     [2026-10-22 18:36:19] [Logged Off, 4, 0] [U:1:…] LogOn() called; not connected yet, scheduling connection. …
    ///     [2026-10-22 18:36:20] [Connecting, 4, 0] [U:1:…] PingWebSocketCM() (cmp1-syd1.steamserver.net:443) starting...
    ///     [2026-10-22 18:36:21] [Connected, 4, 7] [U:1:…] Logging on [U:1:…]
    ///     [2026-10-22 18:36:21] [Logging On, 4, 7] [U:1:…] RecvMsgClientLogOnResponse() : [U:1:…] 'OK'
    ///     [2026-10-22 18:36:21] [Logged On, 4, 7] [U:1:…] RecvMsgClientLogOnResponse() : processing complete
    ///
    /// which takes a couple of seconds online. Before `LogOn() called` the
    /// client is still starting; once logged on, `loginState` says so.
    /// Pass only the new text: the log keeps earlier sessions.
    static func isConnecting(connectionLog: String) -> Bool {
        var connecting = false
        for line in connectionLog.split(whereSeparator: \.isNewline) {
            if line.contains("LogOn() called") {
                connecting = true
            } else if line.contains("[Logged On, ") {
                connecting = false
            }
        }
        return connecting
    }

    /// What an install is doing, from `logs/content_log.txt`.
    enum InstallPhase: Equatable, Sendable {
        /// Nothing logged for the app yet: queued, or not owned (Steam logs
        /// nothing at all for an app the account doesn't own).
        case waiting
        /// One of Steam's update phases: `Preallocating`, `Downloading`,
        /// `Verifying Staged`, `Committing`, …, with the total download size
        /// once Steam has worked it out.
        case updating(phase: String, bytesToDownload: Int64?)
        case installed
        /// The scheduler finished with something other than `No Error`.
        case failed(String)
    }

    /// The latest phase of `appID`'s install in `contentLog`.
    static func installPhase(appID: Int, contentLog: String) -> InstallPhase {
        let prefix = "AppID \(appID) "
        var phase = InstallPhase.waiting
        var total: Int64?
        for line in contentLog.split(whereSeparator: \.isNewline) {
            guard let start = line.range(of: prefix) else { continue }
            let message = line[start.upperBound...]
            if message.hasPrefix("update started : download "),
               let slash = message.firstIndex(of: "/") {
                let digits = message[message.index(after: slash)...].prefix { $0.isNumber }
                total = Int64(digits)
                phase = .updating(phase: "Downloading", bytesToDownload: total)
            } else if message.hasPrefix("App update changed : ") {
                let flags = message.dropFirst("App update changed : ".count)
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0 != "Running Update" }
                if let current = flags.first, current != "None" {
                    phase = .updating(phase: current, bytesToDownload: total)
                }
            } else if message.hasPrefix("state changed : "), message.contains("Fully Installed"),
                      !message.contains("Update Running") {
                phase = .installed
            } else if message.hasPrefix("scheduler finished"),
                      let open = message.range(of: "(result "),
                      let comma = message[open.upperBound...].firstIndex(of: ",") {
                let result = String(message[open.upperBound..<comma])
                if result != "No Error" { phase = .failed(result) }
            }
        }
        return phase
    }

    /// What Steam's bootstrapper is doing, from `logs/bootstrap_log.txt`.
    /// The bootstrapper is the part of steam.exe that checks the client's
    /// files when Steam starts, updates them when they're out of date, and
    /// then hands over to the client.
    enum BootstrapPhase: Equatable, Sendable {
        /// Nothing logged yet, or only its start-up lines.
        case starting
        /// Checking the client's files ("Verifying installation...").
        case verifying
        /// The files checked out: the bootstrapper hands over to the client,
        /// unless an update follows.
        case verified
        /// Downloading an update, with how far it has got once the
        /// bootstrapper says ("Downloading update (216,899 of 255,438 KB)...").
        case downloading(doneKB: Int64?, totalKB: Int64?)
        case extracting
        case installing
        /// The update is in, and the bootstrapper is starting the updated
        /// Steam, which checks its files again.
        case restarting

        /// Whether Steam is updating itself, rather than checking or starting.
        var isUpdating: Bool {
            switch self {
            case .downloading, .extracting, .installing, .restarting: return true
            case .starting, .verifying, .verified: return false
            }
        }
    }

    /// The bootstrapper's latest phase in the text it appended to its log
    /// since Steam started. Pass only the new text: the log keeps earlier
    /// sessions. A start that needs no update logs only
    ///
    ///     [2026-10-20 04:39:39] Startup - updater built Oct 13 2026 11:45:33
    ///     [2026-10-20 04:39:39] Verifying installation...
    ///     [2026-10-20 04:39:39] Verification complete
    ///
    /// and one that does carries on with "Downloading update...", a "Downloading
    /// update (X of Y KB)..." line about four times a second, "Download
    /// complete.", "Extracting package...", "Installing update..." and "Update
    /// complete, launching Steam...". A couple of minutes after the client
    /// starts, a background check for updates ("Background update loop
    /// checking for update") may download one to install at the next start:
    /// that isn't this start's update, so it's left out.
    static func bootstrapPhase(log: String) -> BootstrapPhase {
        var phase = BootstrapPhase.starting
        var inBackground = false
        for line in log.split(whereSeparator: \.isNewline) {
            // "[date time] message"
            let message = line.firstIndex(of: "]").map { line[line.index(after: $0)...] }?
                .trimmingCharacters(in: .whitespaces) ?? String(line)
            if message.hasPrefix("Startup - ") {
                // A new bootstrapper run, the restarted one after an update among them.
                inBackground = false
                if phase != .restarting { phase = .starting }
                continue
            }
            if message.hasPrefix("Background update loop") { inBackground = true }
            guard !inBackground else { continue }
            if message.hasPrefix("Verifying installation") {
                phase = .verifying
            } else if message.hasPrefix("Verification complete") {
                phase = .verified
            } else if message.hasPrefix("Downloading update (") {
                phase = .downloading(doneKB: kilobytes(in: message, before: " of "),
                                     totalKB: kilobytes(in: message, before: " KB"))
            } else if message.hasPrefix("Downloading update") {
                if case .downloading = phase { continue }
                phase = .downloading(doneKB: nil, totalKB: nil)
            } else if message.hasPrefix("Extracting package") {
                phase = .extracting
            } else if message.hasPrefix("Installing update") {
                phase = .installing
            } else if message.hasPrefix("Update complete") {
                phase = .restarting
            }
        }
        return phase
    }

    /// The comma-grouped number just before `marker` in a progress line:
    /// "216,899" before " of ", "255,438" before " KB".
    private static func kilobytes(in message: String, before marker: String) -> Int64? {
        guard let end = message.range(of: marker) else { return nil }
        let digits = message[..<end.lowerBound].reversed().prefix { $0.isNumber || $0 == "," }
        return Int64(String(digits.reversed()).replacingOccurrences(of: ",", with: ""))
    }

    /// The launch prompt Steam shows when the account is already playing a
    /// game on another computer: it asks whether to stop that one.
    static let playingElsewherePrompt = "KickingOtherSession"

    /// The step Steam's launch of `appID` has got to, from
    /// `logs/console_log.txt` ("LaunchApp changed task to CreatingProcess"):
    /// each new one is the launch getting somewhere. Nil before the first.
    /// Pass only the text Steam appended since it started.
    static func launchStep(appID: Int, consoleLog: String) -> String? {
        let tag = "GameAction [AppID \(appID), "
        let marker = "LaunchApp changed task to "
        var step: String?
        for line in consoleLog.split(whereSeparator: \.isNewline) where line.contains(tag) {
            if let range = line.range(of: marker) {
                step = line[range.upperBound...].split(separator: " ").first.map(String.init)
            }
        }
        return step
    }

    /// Waits Steam's launch passes through by itself, in a moment: anything
    /// else that lasts is a question for the player.
    static let routineLaunchPrompts: Set<String> = ["ShowInterstitials", "CreatingProcess"]

    /// What the wrapp logs when Steam's launch waits on that prompt, which
    /// the integration tests look for to say why the game never started.
    static let playingElsewhereMarker = "Steam won't start the game yet: this Steam account is playing a game on another computer, and Steam is asking whether to stop it there"

    /// The prompt Steam's launch of `appID` is waiting on the player for, from
    /// `logs/console_log.txt`, or nil when its latest step isn't a wait. Steam
    /// logs each step of a launch as one of
    ///
    ///     GameAction [AppID 31830, ActionID 1] : LaunchApp changed task to CreatingProcess with ""
    ///     GameAction [AppID 31830, ActionID 1] : LaunchApp waiting for user response to CreatingProcess ""
    ///     GameAction [AppID 31830, ActionID 1] : LaunchApp continues with user response "CreatingProcess"
    ///
    /// Some waits are routine and over in a moment (`ShowInterstitials`,
    /// `CreatingProcess`); `playingElsewherePrompt` is one that lasts until
    /// the player answers. Pass only the text Steam appended since it started.
    static func launchPrompt(appID: Int, consoleLog: String) -> String? {
        let tag = "GameAction [AppID \(appID), "
        let waiting = "LaunchApp waiting for user response to "
        var prompt: String?
        for line in consoleLog.split(whereSeparator: \.isNewline) where line.contains(tag) {
            if let range = line.range(of: waiting) {
                prompt = line[range.upperBound...].split(separator: " ").first.map(String.init)
            } else if line.contains("LaunchApp continues with user response") || line.contains("LaunchApp changed task to") {
                prompt = nil
            }
        }
        return prompt
    }
}
