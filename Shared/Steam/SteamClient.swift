//
//  SteamClient.swift
//  Shared
//
//  The Steam client running inside a wrapp's Wine prefix: start it, see
//  whether it signed in, install and launch games, and stop it. See
//  docs/steam.md for what each step was found to need.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Steam")
/// What Steam and Wine print while it runs, apart from Second Chance's lines about it.
private nonisolated let outputLogger = Logger(label: "au.gare.callum.second-chance.Shared.Wine")

/// What a wrapp build and a wrapp launch need from Steam. The real one is
/// `SteamClient`; tests drive the build with a fake.
nonisolated protocol SteamClientDriving: Sendable {
    /// Restore the shared sign-in from `store` into the prefix, registry
    /// value included. False when there is none to restore. Steam must not
    /// be running.
    func restoreLogin(from store: SteamSessionStore) async throws -> Bool
    /// Save the prefix's sign-in back to `store`, once Wine has stopped.
    func saveLogin(to store: SteamSessionStore, signedIn: Bool) throws -> SteamSessionStore.CaptureResult
    /// Write the manifest that makes Steam install `appID` the next time it
    /// starts. Steam must not be running.
    func queueInstall(appID: Int, installDir: String) throws
    /// Start Steam (and Wine's desktop first). `silent` keeps its main
    /// window hidden; the sign-in window still shows when it needs one.
    func start(silent: Bool) async throws
    /// Wait until Steam has signed in or is asking for credentials.
    func waitForLogin(timeout: TimeInterval) async -> SteamLogs.LoginState
    /// The app IDs the signed-in account owns, once it has signed in. Steam
    /// writes the package cache a few seconds after signing in, so this
    /// waits up to `timeout` for it.
    func ownedAppIDs(timeout: TimeInterval) async throws -> Set<Int>
    func installPhase(appID: Int) -> SteamLogs.InstallPhase
    func manifest(appID: Int) -> SteamAppManifest?
    /// Have Steam launch the game, for the DRM that insists on it.
    func launch(appID: Int) throws
    /// Ask Steam to quit, then end the prefix's Wine session. Returns once
    /// Wine has stopped — after `timeout`, by force.
    func shutdown(timeout: TimeInterval) async
}

nonisolated final class SteamClient: SteamClientDriving, @unchecked Sendable {
    /// Steam inside the prefix, as Wine sees it and as macOS does.
    static let windowsExecutable = #"C:\Program Files (x86)\Steam\steam.exe"#
    static let steamDirInPrefix = "drive_c/Program Files (x86)/Steam"

    let wine: WineEnvironment
    var steamDir: URL { wine.prefixDir.appendingPathComponent(Self.steamDirInPrefix) }
    var logsDir: URL { steamDir.appendingPathComponent("logs") }

    private let state = NSLock()
    private var desktop: WineDesktop?
    /// How long each log was when Steam started: both keep earlier sessions,
    /// and only what this one wrote counts.
    private var logOffsets: [String: UInt64] = [:]

    init(wrappPath: URL) {
        wine = WineEnvironment(appPath: wrappPath)
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: steamDir.appendingPathComponent("steam.exe").path)
    }

    func restoreLogin(from store: SteamSessionStore) async throws -> Bool {
        guard let fragment = try store.restore(into: wine.prefixDir) else { return false }
        defer { try? FileManager.default.removeItem(at: fragment) }
        try await wine.runWine(executable: "wine", arguments: ["reg", "import", SteamSessionStore.fragmentWindowsPath], timeout: 120)
        return true
    }

    func saveLogin(to store: SteamSessionStore, signedIn: Bool) throws -> SteamSessionStore.CaptureResult {
        try store.capture(from: wine.prefixDir, signedIn: signedIn)
    }

    func queueInstall(appID: Int, installDir: String) throws {
        let steamapps = steamDir.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        let manifest = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
        try SteamAppManifest.installStub(appID: appID, installDir: installDir)
            .replacingOccurrences(of: "\n", with: "\r\n")
            .write(to: manifest, atomically: true, encoding: .utf8)
        logger.notice("Queued Steam app \(appID) to install into steamapps/common/\(installDir)")
    }

    func start(silent: Bool) async throws {
        let wine = wine
        // Blocks while it waits for the display devices; keep that off the caller.
        let desktop = await Task.detached {
            WineDesktop.start(wine, logger: logger, outputLogger: outputLogger)
        }.value
        let offsets = Dictionary(uniqueKeysWithValues: ["connection_log.txt", "steamui_login.txt", "content_log.txt"].map {
            ($0, Self.size(of: logsDir.appendingPathComponent($0)))
        })
        state.withLock {
            self.desktop = desktop
            logOffsets = offsets
        }
        try run(silent ? ["-silent"] : [])
        logger.notice("Started Steam\(silent ? " (silent)" : "")")
    }

    func waitForLogin(timeout: TimeInterval) async -> SteamLogs.LoginState {
        let deadline = Date().addingTimeInterval(timeout)
        var result = SteamLogs.LoginState.pending
        while Date() < deadline {
            result = SteamLogs.loginState(connectionLog: newLog("connection_log.txt"), loginLog: newLog("steamui_login.txt"))
            if result != .pending { break }
            try? await Task.sleep(for: .seconds(1))
        }
        switch result {
        case .signedIn: logger.notice("Steam signed in")
        case .needsCredentials(let reason): logger.notice("Steam is asking for credentials\(reason.map { " (\($0))" } ?? "")")
        case .pending: logger.warning("Steam neither signed in nor asked for credentials within \(Int(timeout))s")
        }
        return result
    }

    func ownedAppIDs(timeout: TimeInterval) async throws -> Set<Int> {
        let url = steamDir.appendingPathComponent("appcache/packageinfo.vdf")
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try SteamCaches.ownedAppIDs(packageInfo: Data(contentsOf: url))
            } catch {
                // Not written yet, or caught part-way through being written.
                guard Date() < deadline else {
                    logger.error("Couldn't read the Steam account's licences from \(url.lastPathComponent) within \(Int(timeout))s: \(error.localizedDescription)")
                    throw error
                }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    func installPhase(appID: Int) -> SteamLogs.InstallPhase {
        SteamLogs.installPhase(appID: appID, contentLog: newLog("content_log.txt"))
    }

    func manifest(appID: Int) -> SteamAppManifest? {
        let url = steamDir.appendingPathComponent("steamapps/appmanifest_\(appID).acf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return SteamAppManifest(text: text)
    }

    func launch(appID: Int) throws {
        try run(["-silent", "-applaunch", String(appID)])
        logger.notice("Asked Steam to launch app \(appID)")
    }

    func shutdown(timeout: TimeInterval) async {
        let start = Date()
        logger.notice("Shutting Steam down")
        do {
            try run(["-shutdown"])
        } catch {
            logger.warning("Couldn't ask Steam to shut down: \(error.localizedDescription)")
        }
        state.withLock { desktop }?.release()
        // Steam usually exits within seconds, but has been seen to leave a
        // web helper running for minutes; waiting on the whole session
        // covers every Steam process, and the timeout covers the stragglers.
        let wine = wine
        let stopped = await Task.detached {
            while Date().timeIntervalSince(start) < timeout {
                if !wine.isWineserverRunning() { return true }
                try? await Task.sleep(for: .seconds(1))
            }
            return false
        }.value
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
        if stopped {
            logger.notice("Steam and its Wine session stopped after \(elapsed)s")
        } else {
            logger.warning("Steam's Wine session was still running after \(elapsed)s; stopping it")
            wine.stopWineserver()
        }
    }

    // MARK: Helpers

    /// Run steam.exe with `arguments` without waiting: the bootstrapper hands
    /// over to the client and exits (42 after an update), and the client runs
    /// until it is told to stop.
    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = wine.wineBinDir.appendingPathComponent("wine")
        process.arguments = [Self.windowsExecutable] + arguments
        process.environment = wine.environmentVariables()
        process.standardInput = FileHandle.nullDevice
        // Not read to EOF: Wine's services inherit the pipes and hold them open.
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        ProcessLineLogger.attach(to: output, logger: outputLogger, level: .notice)
        ProcessLineLogger.attach(to: errors, logger: outputLogger, level: .warning)
        try process.run()
    }

    /// What `name` gained since Steam started.
    private func newLog(_ name: String) -> String {
        let url = logsDir.appendingPathComponent(name)
        let offset = state.withLock { logOffsets[name] } ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        // Steam truncates a log that grows too large; start again from the top.
        let size = Self.size(of: url)
        try? handle.seek(toOffset: size < offset ? 0 : offset)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    private static func size(of url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
