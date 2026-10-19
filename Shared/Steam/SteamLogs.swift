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
}
