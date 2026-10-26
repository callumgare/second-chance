//
//  SteamWrappBuilder.swift
//  SecondChance
//
//  The per-source orchestrator for building a wrapp from Steam.
//
//  Unlike the installer-based sources no setup.exe runs: the Steam client is
//  installed into the wrapp, signed in with the shared session (or by the
//  user, once), told to install the game, and then shut down; the game is
//  then configured like any other. docs/steam.md has why each step is as it
//  is.
//

import Foundation
import Logging

/// Makes the wrapp Steam is installed into: the template, a Wine prefix and
/// the Steam client. Tests stand in a small fake bundle.
///
/// A protocol rather than an injected `async` closure: an optional async
/// closure given a default with `??` crossed the main actor in as its first
/// argument under this project's concurrency settings, and the "URL" the
/// closure got was the `MainActor` object.
protocol SteamWrappPreparing {
    func prepare(wrappAt path: URL) async throws
}

struct SteamWrappPreparer: SteamWrappPreparing {
    let helper: WrappBuildHelper
    let clientCache: SteamClientCache

    func prepare(wrappAt path: URL) async throws {
        try await helper.createBaseWrapp(at: path)
        try await helper.installSteamClient(in: path)
        clientCache.restore(into: path.appendingPathComponent("Contents/SharedSupport/prefix"))
    }
}

/// Builds a wrapp from a game in the user's Steam library.
final class SteamWrappBuilder: WrappBuildStrategy {
    private let helper: WrappBuildHelper
    private let installerRunner: GameInstallerRunner
    private let gameInfoProvider: GameInfoProvider
    private let sessionStore: SteamSessionStore
    private let clientCache: SteamClientCache
    private let lockRoot: URL
    private let makeClient: (URL) -> SteamClientDriving
    private let preparer: SteamWrappPreparing
    let bus: EventBus<AppEvent>
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.SteamWrappBuilder")

    /// How long a person gets to sign in to the window Steam shows.
    static let signInTimeout: TimeInterval = 30 * 60
    /// Steam's first start in a wrapp updates the client before it signs in.
    static let startTimeout: TimeInterval = 20 * 60
    /// A whole download, for the slowest connection worth waiting on.
    static let installTimeout: TimeInterval = 4 * 60 * 60
    /// How long a quit waits for Steam to shut down before ending its Wine
    /// session by force: the user is waiting for the app to go.
    static let quitShutdownTimeout: TimeInterval = 10

    init(
        helper: WrappBuildHelper = .shared,
        installerRunner: GameInstallerRunner = .shared,
        gameInfoProvider: GameInfoProvider = .shared,
        sessionStore: SteamSessionStore = SteamSessionStore(),
        clientCache: SteamClientCache = .shared,
        lockRoot: URL = SteamSessionStore.defaultRoot,
        makeClient: ((URL) -> SteamClientDriving)? = nil,
        preparer: SteamWrappPreparing? = nil,
        bus: EventBus<AppEvent> = .app
    ) {
        self.helper = helper
        self.installerRunner = installerRunner
        self.gameInfoProvider = gameInfoProvider
        self.sessionStore = sessionStore
        self.clientCache = clientCache
        self.lockRoot = lockRoot
        self.makeClient = makeClient ?? { SteamClient(wrappPath: $0) }
        self.preparer = preparer ?? SteamWrappPreparer(helper: helper, clientCache: clientCache)
        self.bus = bus
    }

    /// Take the one-Steam-at-a-time lock, asking the person what to do while
    /// a game holds it: they can quit it themselves and try again, have it
    /// quit for them, or give up, which is a cancel rather than a failure.
    private func takeSteamLock(input: WrappBuildInput) async throws -> SteamActiveLock {
        while true {
            switch try SteamActiveLock.acquire(root: lockRoot, bundleID: SteamLockHolder.buildBundleID) {
            case .acquired(let lock):
                return lock
            case .heldBy(let holder):
                logger.notice("Steam is in use by \(holder.name ?? "another process") (\(holder.bundleID ?? "unknown"), pid \(holder.pid.map(String.init) ?? "unknown"))")
                switch await input.askAboutSteamInUse(holder) {
                case nil:
                    throw WrappBuildError.steamInUse(holder)
                case .tryAgain:
                    continue
                case .cancel:
                    throw WrappBuildError.userCancelledBeforeStart
                case .quitHolder:
                    let gone = await Task.detached { holder.quit() }.value
                    if !gone { throw WrappBuildError.steamInUse(holder) }
                }
            }
        }
    }

    func build(input: WrappBuildInput) async throws -> URL {
        await bus.publishWrappBuild(.started(source: .steam))

        // A game named up front (headless, tests) is queued before Steam's
        // first start; otherwise the user picks once Steam has signed in, from
        // the games the account owns, and Steam restarts to install it.
        let preselected: GameInfo?
        do {
            preselected = try input.steamGameFromEnvironment(among: gameInfoProvider.allGames())
        } catch {
            await bus.publishWrappBuild(.failed((error as? WrappBuildError) ?? .internalError(error.localizedDescription)))
            throw error
        }

        // ── One Steam at a time ────────────────────────────────────────
        let lock: SteamActiveLock
        do {
            lock = try await takeSteamLock(input: input)
        } catch {
            await bus.publishWrappBuild(.failed((error as? WrappBuildError) ?? .internalError(error.localizedDescription)))
            throw error
        }
        defer { lock.release() }

        // ── Build ──────────────────────────────────────────────────────
        let wrappPath = helper.createTemporaryWrappPath()
        let prefix = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix")
        logger.notice("Temporary wrapp: \(wrappPath.path)")
        let client = makeClient(wrappPath)
        // Quitting the app stops this build's Steam: it would otherwise keep
        // running, its window open, from a temporary wrapp the quit deletes.
        let run = SteamRun()
        let quitStop = RunningSteam.shared.register { [self] in
            if run.claimStop() {
                await stopSteam(client, prefix: prefix, signedIn: run.signedIn, timeout: Self.quitShutdownTimeout)
            }
        }
        defer { RunningSteam.shared.unregister(quitStop) }

        do {
            try await preparer.prepare(wrappAt: wrappPath)

            // Sign in with the shared session when there is one.
            await bus.publishWrappBuild(.progress(.installingGame(substep: "Starting Steam")))
            let restored = try await client.restoreLogin(from: sessionStore)
            if !restored && !input.canSignInToSteam { throw WrappBuildError.steamSignInRequired }
            if let preselected, let steam = Self.steamData(preselected) {
                try client.queueInstall(appID: steam.appID, installDir: steam.installDir)
            }
            // Without a saved sign-in, Steam's window is about to ask for one.
            if !sessionStore.hasSession && input.canSignInToSteam {
                await bus.publishWrappBuild(.instructions(Self.signInInstructions))
            }
            try await client.start(silent: true)
            run.started()

            run.signedIn = try await signIn(client: client, input: input)
            await bus.publishWrappBuild(.instructions(nil))

            // ── Pick the game ──────────────────────────────────────────
            await bus.publishWrappBuild(.progress(.installingGame(substep: "Checking which games your Steam account owns")))
            let owned = try await client.ownedAppIDs(timeout: 120)
            let ownedGames = gameInfoProvider.allGames().filter { $0.isOnSteam && $0.steamAppID.map(owned.contains) == true }
            logger.notice("The Steam account owns \(ownedGames.count) of the games: \(ownedGames.map(\.id).joined(separator: ", "))")
            await bus.publishWrappBuild(.steamGamesOwned(ownedGames))
            let gameInfo: GameInfo
            if let preselected {
                guard ownedGames.contains(where: { $0.id == preselected.id }) else {
                    throw WrappBuildError.steamGameNotOwned(title: preselected.title)
                }
                gameInfo = preselected
            } else {
                guard !ownedGames.isEmpty else { throw WrappBuildError.steamNoGamesOwned }
                gameInfo = try await input.chooseSteamGame(from: ownedGames)
            }
            await bus.publishWrappBuild(.gameDetected(gameInfo))
            try await input.onGameDetected(gameInfo)
            let launchMode = gameInfo.offersSteamLaunchChoice ? try await input.getSteamLaunchMode(for: gameInfo) : nil
            guard let steam = Self.steamData(gameInfo) else {
                throw WrappBuildError.internalError("\(gameInfo.title) has no Steam app data")
            }
            let (appID, installDir, exe) = (steam.appID, steam.installDir, steam.exe)
            let engine = gameInfo.steamEngine(launchMode: launchMode)
            await bus.publishWrappBuild(.engineRouted(engine: engine, gameInfo: gameInfo))
            logger.notice("Building \(gameInfo.title) from Steam (app \(appID)), engine \(engine.rawValue)\(launchMode.map { ", launching \($0.rawValue)" } ?? "")")

            if preselected == nil {
                // Steam only installs a queued game when it starts.
                await bus.publishWrappBuild(.progress(.installingGame(substep: "Restarting Steam to install \(gameInfo.title)")))
                if run.claimStop() {
                    await stopSteam(client, prefix: prefix, signedIn: run.signedIn, keepSignIn: true)
                }
                try client.queueInstall(appID: appID, installDir: installDir)
                try await client.start(silent: true)
                run.started()
                run.signedIn = try await signIn(client: client, input: input)
            }

            try await waitForInstall(client: client, appID: appID)

            if run.claimStop() {
                await stopSteam(client, prefix: prefix, signedIn: run.signedIn)
            }
            clientCache.save(from: prefix)
            // Nothing from here on uses Steam or its sign-in. Holding the lock
            // through patching and saving had a wrapp opened as the build
            // finished (or from its done screen) find Steam taken by the build.
            lock.release()

            // ── Locate and configure ───────────────────────────────────
            let steamGameDir = prefix.appendingPathComponent(SteamClient.steamDirInPrefix)
                .appendingPathComponent("steamapps/common").appendingPathComponent(installDir)
            guard FileManager.default.fileExists(atPath: steamGameDir.appendingPathComponent(exe).path) else {
                logger.critical("Steam finished, but \(exe) isn't in \(steamGameDir.path)")
                throw WrappBuildError.gameExecutableNotFound
            }

            let runsWithoutSteam = engine == .wine || engine == .scummvm
            let gameDir = runsWithoutSteam ? try moveOutOfSteam(steamGameDir, prefix: prefix, installDir: installDir) : steamGameDir
            let driveC = prefix.appendingPathComponent("drive_c")
            let gameDirPath = "/" + gameDir.path(relativeTo: driveC)
            let gameExePath = engine == .scummvm ? gameDirPath : gameDirPath + "/" + exe
            await bus.publishWrappBuild(.gameExeDetected(path: gameExePath, gameInfo: gameInfo))

            await bus.publishWrappBuild(.progress(.configuringWrapp(substep: "Applying game patches")))
            do {
                try await installerRunner.applyGamePatches(wrappPath: wrappPath, gameInfo: gameInfo, gameInstallDir: gameDir, source: .steam)
            } catch WrappBuildError.userCancelled {
                throw WrappBuildError.userCancelled
            } catch {
                logger.warning("⚠️  Failed to apply patches: \(error)")
            }

            if runsWithoutSteam { try removeSteam(from: prefix) }
            try await helper.cleanupUnusedEngine(at: wrappPath, gameEngine: engine)

            try helper.configureWrapp(
                at: wrappPath,
                gameInfo: gameInfo,
                source: .steam,
                gameExePath: gameExePath,
                installerDir: gameDirPath,
                steamID: runsWithoutSteam ? nil : String(appID),
                gameEngine: engine,
                steamLaunchMode: launchMode
            )
            await bus.publishWrappBuild(.wrappConfigured(exePath: gameExePath, installerDir: gameDirPath, gameInfo: gameInfo))

            let finalPath = try await helper.finalize(wrapp: wrappPath, gameInfo: gameInfo, input: input)
            helper.unregisterTemporaryWrapp(wrappPath)

            let (shouldLaunch, args) = await input.shouldLaunchGame()
            if shouldLaunch {
                try await helper.launchGame(at: finalPath, with: args)
            }
            return finalPath
        } catch {
            if run.claimStop() {
                await stopSteam(client, prefix: prefix, signedIn: run.signedIn)
            }
            await helper.removeTempWrapp(wrappPath)

            let buildError = (error as? WrappBuildError) ?? .internalError(error.localizedDescription)
            await bus.publishWrappBuild(.failed(buildError))
            throw error
        }
    }

    // MARK: - Steps

    /// What Steam needs to install `game`, and the exe it will put there.
    private static func steamData(_ game: GameInfo) -> (appID: Int, installDir: String, exe: String)? {
        guard let appID = game.steamAppID, let installDir = game.steamInstallDir, let exe = game.steamExePath else { return nil }
        return (appID, installDir, exe)
    }

    /// What the progress screen says while Steam wants a sign-in.
    static let signInInstructions = "Steam opens in its own window. Sign in there, or scan its QR code with the Steam app on your phone. "
        + "You'll stay signed in for your other Nancy Drew games, until you choose Second Chance ▸ Sign Out of Steam."

    /// Wait for Steam to sign in, asking the user when it shows its sign-in
    /// window. True once signed in.
    private func signIn(client: SteamClientDriving, input: WrappBuildInput) async throws -> Bool {
        switch await client.waitForLogin(timeout: Self.startTimeout) {
        case .signedIn:
            return true
        case .pending:
            throw WrappBuildError.steamSignInTimedOut
        case .needsCredentials(let reason):
            logger.notice("Steam wants a sign-in\(reason.map { " (\($0))" } ?? "")")
            guard input.canSignInToSteam else { throw WrappBuildError.steamSignInRequired }
            await bus.publishWrappBuild(.progress(.installingGame(substep: "Waiting for you to sign in to Steam")))
            await bus.publishWrappBuild(.instructions(Self.signInInstructions))
            await client.bringSignInWindowForward()
            let deadline = Date().addingTimeInterval(Self.signInTimeout)
            while Date() < deadline {
                if await client.waitForLogin(timeout: 2) == .signedIn { return true }
                try await Task.sleep(for: .seconds(2))
            }
            throw WrappBuildError.steamSignInTimedOut
        }
    }

    private func waitForInstall(client: SteamClientDriving, appID: Int) async throws {
        let deadline = Date().addingTimeInterval(Self.installTimeout)
        var lastSubstep = ""
        while Date() < deadline {
            let phase = client.installPhase(appID: appID)
            switch phase {
            case .installed:
                if client.manifest(appID: appID)?.isFullyInstalled != false { return }
            case .failed(let reason):
                throw WrappBuildError.steamInstallFailed(reason: reason)
            case .waiting, .updating:
                break
            }
            let substep = Self.substep(for: phase)
            if substep != lastSubstep {
                lastSubstep = substep
                await bus.publishWrappBuild(.progress(.installingGame(substep: substep)))
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw WrappBuildError.steamInstallFailed(reason: "it was still going after \(Int(Self.installTimeout / 3600)) hours")
    }

    /// What the progress line says during an install. Steam gives phases and
    /// a total, never a running count, so there's no percentage to show.
    static func substep(for phase: SteamLogs.InstallPhase) -> String {
        switch phase {
        case .waiting:
            return "Waiting for Steam to start the download"
        case .updating(let name, let total):
            let size = total.map { " " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            switch name {
            case "Downloading", "Staging": return "Downloading\(size) through Steam"
            case "Verifying Staged", "Verifying Install": return "Checking the download"
            case "Committing": return "Finishing the install"
            default: return "Preparing the download"
            }
        case .installed:
            return "Installed"
        case .failed(let reason):
            return "Install failed: \(reason)"
        }
    }

    /// Stop Steam, save a signed-in session to the shared store, then take
    /// the sign-in out of the wrapp: it would otherwise ship inside the app,
    /// and anyone given a copy could use the account. `keepSignIn` leaves it
    /// in for Steam to start again with, as the build itself does.
    private func stopSteam(_ client: SteamClientDriving, prefix: URL, signedIn: Bool, keepSignIn: Bool = false,
                           timeout: TimeInterval = 90) async {
        await client.shutdown(timeout: timeout)
        do {
            let result = try client.saveLogin(to: sessionStore, signedIn: signedIn)
            logger.notice("Steam session: \(String(describing: result))")
        } catch {
            logger.warning("Couldn't save the Steam session: \(error.localizedDescription)")
        }
        if !keepSignIn { SteamSessionStore.strip(from: prefix) }
    }

    /// Move the game out of Steam's library so Steam can be removed.
    private func moveOutOfSteam(_ gameDir: URL, prefix: URL, installDir: String) throws -> URL {
        let destination = prefix.appendingPathComponent("drive_c/Program Files (x86)/Nancy Drew").appendingPathComponent(installDir)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: gameDir, to: destination)
        return destination
    }

    /// Take the Steam client out of a wrapp that runs its game without it.
    private func removeSteam(from prefix: URL) throws {
        for path in [SteamClient.steamDirInPrefix, "drive_c/Program Files (x86)/Common Files/Steam"] {
            let url = prefix.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        logger.notice("Removed the Steam client from the wrapp")
    }
}
