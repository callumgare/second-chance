//
//  SteamClient.swift
//  Shared
//
//  The Steam client running inside a wrapp's Wine prefix: start it, see
//  whether it signed in, install and launch games, and stop it. See
//  docs/steam.md for what each step was found to need.

import Foundation
import Logging
import WrappFormat

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Steam")
/// What Steam and Wine print while it runs, apart from Second Chance's lines about it.
private nonisolated let outputLogger = Logger(label: "au.gare.callum.second-chance.Shared.Wine")

/// What a wrapp build and a wrapp launch need from Steam. The real one is
/// `SteamClient`; tests drive the build with a fake.
nonisolated public protocol SteamClientDriving: Sendable {
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
    /// Where the sign-in has got to now, without waiting or logging.
    func loginState() -> SteamLogs.LoginState
    /// What the bootstrapper has got to in this start (`SteamLogs.bootstrapPhase`).
    func bootstrapPhase() -> SteamLogs.BootstrapPhase
    /// Whether the client is connecting to Steam's servers, not yet signed in
    /// (`SteamLogs.isConnecting`).
    func isConnecting() -> Bool
    /// Whether Steam is running. It exits and starts again when it has
    /// updated itself, so one check that finds it missing proves nothing.
    func isRunning() -> Bool
    /// When Steam last wrote to any of its logs, or nil if it has none yet.
    func lastLogWrite() -> Date?
    /// Bring Steam's sign-in window to the front, once it's asking for one:
    /// it may be minutes since the player last looked (`SteamSignInWindow`).
    func bringSignInWindowForward() async
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

nonisolated public final class SteamClient: SteamClientDriving, @unchecked Sendable {
    /// Steam inside the prefix, as Wine sees it and as macOS does.
    static let windowsExecutable = #"C:\Program Files (x86)\Steam\steam.exe"#
    public static let steamDirInPrefix = "drive_c/Program Files (x86)/Steam"

    public let wine: Wine
    var steamDir: URL { wine.prefix.appendingPathComponent(Self.steamDirInPrefix) }
    var logsDir: URL { steamDir.appendingPathComponent("logs") }

    private let state = NSLock()
    private var desktop: WineDesktop?
    /// How long each log was when Steam started: both keep earlier sessions,
    /// and only what this one wrote counts.
    private var logOffsets: [String: UInt64] = [:]

    /// The exe of the game Steam will launch, whose in-process helpers
    /// (native fullscreen, cursor lock) are armed through Steam's environment:
    /// a game Steam starts gets Steam's, not the `-applaunch` call's.
    private let gameExe: URL?
    /// The game's launch, which says which of its helpers to arm.
    private let launch: RecordedLaunch?
    /// Sees each line Steam's processes print — the game's among them, when
    /// Steam launches it.
    private let onOutputLine: (@Sendable (String) -> Void)?

    /// `prefixDir` when the wrapp runs from a prefix outside its bundle
    /// (a read-only wrapp's copy; see the wrapp's `getWinePrefix`). `gameExe`,
    /// the game's .exe, when Steam will launch a game — not while a build
    /// installs one.
    public init(wrappPath: URL, prefixDir: URL? = nil, gameExe: URL? = nil, launch: RecordedLaunch? = nil, onOutputLine: (@Sendable (String) -> Void)? = nil) {
        wine = Wine(wrapp: wrappPath, prefix: prefixDir)
        self.gameExe = gameExe
        self.launch = launch
        self.onOutputLine = onOutputLine
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: steamDir.appendingPathComponent("steam.exe").path)
    }

    public func restoreLogin(from store: SteamSessionStore) async throws -> Bool {
        guard let fragment = try store.restore(into: wine.prefix) else { return false }
        defer { try? FileManager.default.removeItem(at: fragment) }
        try await wine.run(.wine(["reg", "import", SteamSessionStore.fragmentWindowsPath]), timeout: 120)
        return true
    }

    public func saveLogin(to store: SteamSessionStore, signedIn: Bool) throws -> SteamSessionStore.CaptureResult {
        try store.capture(from: wine.prefix, signedIn: signedIn)
    }

    public func queueInstall(appID: Int, installDir: String) throws {
        let steamapps = steamDir.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        let manifest = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
        try SteamAppManifest.installStub(appID: appID, installDir: installDir)
            .replacingOccurrences(of: "\n", with: "\r\n")
            .write(to: manifest, atomically: true, encoding: .utf8)
        logger.notice("Queued Steam app \(appID) to install into steamapps/common/\(installDir)")
    }

    public func start(silent: Bool) async throws {
        let desktop = await WineDesktop.start(wine, logger: logger, outputLogger: outputLogger)
        let offsets = Dictionary(uniqueKeysWithValues: Self.followedLogs.map {
            ($0, Self.size(of: logsDir.appendingPathComponent($0)))
        })
        state.withLock {
            self.desktop = desktop
            logOffsets = offsets
        }
        try run(silent ? ["-silent"] : [])
        logger.notice("Started Steam\(silent ? " (silent)" : "")")
    }

    public func lastLogWrite() -> Date? {
        let files = (try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
    }

    public func bringSignInWindowForward() async {
        await SteamSignInWindow.bringForward()
    }

    public func waitForLogin(timeout: TimeInterval) async -> SteamLogs.LoginState {
        let deadline = Date().addingTimeInterval(timeout)
        var result = SteamLogs.LoginState.pending
        while Date() < deadline {
            result = loginState()
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

    /// Where the sign-in has got to now, without waiting or logging.
    public func loginState() -> SteamLogs.LoginState {
        SteamLogs.loginState(connectionLog: newLog("connection_log.txt"), loginLog: newLog("steamui_login.txt"))
    }

    /// Whether the client is connecting to Steam's servers, not yet signed in
    /// (`SteamLogs.isConnecting`).
    public func isConnecting() -> Bool {
        SteamLogs.isConnecting(connectionLog: newLog("connection_log.txt"))
    }

    /// What the bootstrapper has got to in this start: checking the client's
    /// files, or updating them (`SteamLogs.bootstrapPhase`).
    public func bootstrapPhase() -> SteamLogs.BootstrapPhase {
        SteamLogs.bootstrapPhase(log: newLog("bootstrap_log.txt"))
    }

    /// Whether `steam.exe` is running. Only one wrapp or build runs Steam at
    /// a time (`SteamActiveLock`), so any running is this prefix's.
    public static func isSteamRunning() -> Bool {
        ProcessList.isRunning("steam.exe")
    }

    public func isRunning() -> Bool { Self.isSteamRunning() }

    public func ownedAppIDs(timeout: TimeInterval) async throws -> Set<Int> {
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

    public func installPhase(appID: Int) -> SteamLogs.InstallPhase {
        SteamLogs.installPhase(appID: appID, contentLog: newLog("content_log.txt"))
    }

    /// The step Steam's launch of `appID` has got to (`SteamLogs.launchStep`).
    public func launchStep(appID: Int) -> String? {
        SteamLogs.launchStep(appID: appID, consoleLog: newLog("console_log.txt"))
    }

    /// What Steam's launch of `appID` is waiting on the player for, if
    /// anything (`SteamLogs.launchPrompt`).
    public func launchPrompt(appID: Int) -> String? {
        SteamLogs.launchPrompt(appID: appID, consoleLog: newLog("console_log.txt"))
    }

    public func manifest(appID: Int) -> SteamAppManifest? {
        let url = steamDir.appendingPathComponent("steamapps/appmanifest_\(appID).acf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return SteamAppManifest(text: text)
    }

    public func launch(appID: Int) throws {
        try run(["-silent", "-applaunch", String(appID)])
        logger.notice("Asked Steam to launch app \(appID)")
    }

    public func shutdown(timeout: TimeInterval) async {
        let start = Date()
        logger.notice("Shutting Steam down")
        // `steam.exe -shutdown` with no Steam to tell starts a Wine session
        // of its own, whose errors (the wrapp being deleted beneath it) then
        // look like the cause of whatever failed.
        if Self.isSteamRunning() {
            do {
                try run(["-shutdown"])
            } catch {
                logger.warning("Couldn't ask Steam to shut down: \(error.localizedDescription)")
            }
        } else {
            logger.notice("Steam isn't running; ending its Wine session")
        }
        state.withLock { desktop }?.release()
        // Steam usually exits within seconds, but has been seen to leave a
        // web helper running for minutes; waiting on the whole session
        // covers every Steam process, and the timeout covers the stragglers.
        // Steam has taken up to ~20 s; past that, which program holds the
        // session open is what a slow shutdown's cause is found from, and
        // once the session is stopped (or the wrapp killed) it's gone.
        let usual: TimeInterval = 25
        var stopped = await wine.server.waitUntilStopped(timeout: max(0, min(usual, timeout) - Date().timeIntervalSince(start)))
        if !stopped {
            let running = await Self.runningWinePrograms()
            logger.notice("Steam's Wine session is still running after \(String(format: "%.1f", Date().timeIntervalSince(start)))s: \(running)")
            stopped = await wine.server.waitUntilStopped(timeout: max(0, timeout - Date().timeIntervalSince(start)))
        }
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
        if stopped {
            logger.notice("Steam and its Wine session stopped after \(elapsed)s")
        } else {
            let running = await Self.runningWinePrograms()
            logger.warning("Steam's Wine session was still running after \(elapsed)s; stopping it. \(running)")
            await wine.server.stop()
        }
    }

    /// The Wine programs running, for the log.
    private static func runningWinePrograms() async -> String {
        let programs = await Blocking.run { ProcessList.current()?.wine.map { "\($0.name) (pid \($0.pid), parent \($0.parent))" } ?? [] }
        return programs.isEmpty ? "no Wine programs are running" : "Wine programs running: \(programs.joined(separator: ", "))"
    }

    // MARK: Helpers

    /// Run steam.exe with `arguments` without waiting: the bootstrapper hands
    /// over to the client and exits (42 after an update), and the client runs
    /// until it is told to stop.
    private func run(_ arguments: [String]) throws {
        _ = try wine.start(.program(Self.windowsExecutable, arguments),
                           environment: gameExe.map { Wine.inProcessHelperVariables(gameExe: $0, launch: launch) } ?? [:],
                           output: .log(outputLogger, onLine: onOutputLine))
    }

    /// The logs whose new text this start reads.
    private static let followedLogs = ["connection_log.txt", "steamui_login.txt", "content_log.txt", "console_log.txt", "bootstrap_log.txt"]

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

    /// The size of the file itself: a read-only wrapp's prefix has its larger
    /// files as symlinks into the bundle (`getWinePrefix`), and the size of
    /// the link would have every earlier session's log read as new.
    private static func size(of url: URL) -> UInt64 {
        let path = url.resolvingSymlinksInPath().path
        return ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
