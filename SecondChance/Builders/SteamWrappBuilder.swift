//
//  SteamWrappBuilder.swift
//  SecondChance
//
//  The per-source orchestrator for building a wrapp from Steam.
//
//  Unlike the installer-based sources no setup.exe runs: the steam
//  module's client stage installs Steam into the wrapp, it is signed in with
//  the shared session (or by the user, once), and the game's Steam edition's
//  steps install the game (`STEAM.INSTALL`), take the sign-in out
//  (`STEAM.SIGN-OUT`) and, for a game started without Steam, Steam itself
//  (`STEAM.REMOVE`). docs/steam.md has why each step is as it is.
//

import Foundation
import Logging
import SecondChanceKit
import GameCatalog
import WrappBuilder
import WrappFormat

/// Makes the wrapp Steam is installed into: the template, a Wine prefix and
/// the Steam client. Tests stand in a small fake bundle.
///
/// A protocol rather than an injected `async` closure: an optional async
/// closure given a default with `??` crossed the main actor in as its first
/// argument under this project's concurrency settings, and the "URL" the
/// closure got was the `MainActor` object.
protocol SteamWrappPreparing {
    func prepare(wrappAt path: URL) async throws
    /// One of the Wine steps a game's Steam stage has of its own
    /// (cnc-ddraw's), carried out in the wrapp's prefix.
    func run(_ step: PlannedStep, in path: URL) async throws
}

struct SteamWrappPreparer: SteamWrappPreparing {
    let helper: WrappBuildHelper
    let clientCache: SteamClientCache

    func run(_ step: PlannedStep, in path: URL) async throws {
        try await WineSteps(bus: helper.bus).run(step, wrappPath: path)
    }

    /// The template and the wine module's prefix, then the steam module's
    /// `client` stage's steps (`FROM steam@1/client`): Steam installed, and
    /// ⌘ acting as Ctrl in its windows. What a game's Steam stage is built
    /// from, carried out before the game is known, as Steam must be signed
    /// in to say which games the account owns.
    func prepare(wrappAt path: URL) async throws {
        try await helper.createBaseWrapp(at: path)
        for step in try await SteamWrappBuilder.clientStage().steps {
            switch (step.module, step.instruction) {
            case ("steam", "CLIENT"): try await helper.installSteamClient(in: path)
            case _ where WineSteps.handles(step): try await run(step, in: path)
            default: throw WrappBuildError.buildRecipeProblem("\(step.origin): this build can't run \(step)")
            }
        }
        // The client STEAM.INSTALL's cache mount keeps, put back before
        // Steam's first start, which signs in: hundreds of MB, so off the
        // main thread.
        let clientCache = self.clientCache
        let prefix = WrappLayout(app: path).prefix
        _ = await Blocking.run { clientCache.restore(into: prefix) }
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
    /// How often the sign-in wait looks at Steam.
    private let signInPollInterval: Duration
    /// How often the install wait looks at Steam.
    private let installPollInterval: Duration
    /// What Wine has received, for the download's progress.
    private let networkCounter: WineNetworkCounting
    /// How long a download may get nowhere before the person is told, and
    /// before the build gives up on it. Steam keeps retrying by itself, and
    /// a connection that drops for a while is worth waiting out.
    private let downloadStallNote: TimeInterval
    private let downloadStallLimit: TimeInterval
    /// How many looks in a row must find Steam missing before it counts as
    /// exited: it restarts itself after an update (exit 42), which leaves a
    /// moment with no steam.exe.
    private let steamExitedChecks: Int
    /// How long Steam may write nothing to its logs, before it has signed
    /// in or asked for credentials, before it counts as stuck
    /// (`SteamSignInWatch.quietLimit`).
    private let signInQuietLimit: TimeInterval
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
        signInPollInterval: Duration = .seconds(2),
        installPollInterval: Duration = .seconds(2),
        networkCounter: WineNetworkCounting = NettopNetworkCounter(),
        downloadStallNote: TimeInterval = 60,
        downloadStallLimit: TimeInterval = 30 * 60,
        steamExitedChecks: Int = 8,
        signInQuietLimit: TimeInterval = SteamSignInWatch.quietLimit,
        bus: EventBus<AppEvent> = .app
    ) {
        self.signInPollInterval = signInPollInterval
        self.installPollInterval = installPollInterval
        self.networkCounter = networkCounter
        self.downloadStallNote = downloadStallNote
        self.downloadStallLimit = downloadStallLimit
        self.steamExitedChecks = steamExitedChecks
        self.signInQuietLimit = signInQuietLimit
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
        let taking = try await SteamActiveLock.take(root: lockRoot, bundleID: SteamLockHolder.buildBundleID) {
            await input.askAboutSteamInUse($0)
        }
        switch taking {
        case .acquired(let lock): return lock
        case .cancelled: throw WrappBuildError.userCancelledBeforeStart
        case .held(let holder): throw WrappBuildError.steamInUse(holder)
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
            await bus.publishWrappBuild(.failed(WrappBuildError(error)))
            throw error
        }

        // ── One Steam at a time ────────────────────────────────────────
        let lock: SteamActiveLock
        do {
            lock = try await takeSteamLock(input: input)
        } catch {
            await bus.publishWrappBuild(.failed(WrappBuildError(error)))
            throw error
        }
        defer { lock.release() }

        // ── Build ──────────────────────────────────────────────────────
        let wrappPath = helper.createTemporaryWrappPath()
        let prefix = WrappLayout(app: wrappPath).prefix
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
            await bus.publishWrappBuild(.progress(.installingGame(substep: SteamStartupStage.starting.message)))
            let restored = try await client.restoreLogin(from: sessionStore)
            if !restored && !input.canSignInToSteam { throw WrappBuildError.steamSignInRequired }
            if let preselected, let steam = Self.steamData(preselected) {
                try client.queueInstall(appID: steam.appID, installDir: steam.installDir)
            }
            try await client.start(silent: true)
            run.started()

            run.signedIn = try await signIn(client: client, prefix: prefix, input: input)
            await bus.publishWrappBuild(.instructions(nil))

            // ── Pick the game ──────────────────────────────────────────
            await bus.publishWrappBuild(.progress(.installingGame(substep: String(localized: "Checking which games your Steam account owns"))))
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
            // The game's Steam edition, as the person's answer decides it.
            let slug = gameInfo.id
            let plan = try await Blocking.run {
                try ShippedBundles.plan(forGame: slug, edition: "steam", choices: launchMode.map { ["launch-mode": $0] } ?? [:])
            }
            guard let plan, let launch = plan.launch else {
                throw WrappBuildError.buildRecipeProblem("\(gameInfo.id)'s Steam edition has no stage")
            }
            let composition = Composition(launch: launch)
            await bus.publishWrappBuild(.engineRouted(composition: composition, gameInfo: gameInfo))
            logger.notice("Building \(gameInfo.title) from Steam (app \(steam.appID)), engine \(composition.engineTag)\(launchMode.map { ", launching \($0)" } ?? "")")

            var queued = preselected != nil
            for step in plan.bundleSteps {
                logger.debug("Plan step: \(step) (\(step.origin))")
                switch (step.module, step.instruction) {
                case ("steam", "INSTALL"):
                    if !queued {
                        // Steam only installs a queued game when it starts.
                        await bus.publishWrappBuild(.progress(.installingGame(substep: String(localized: "Restarting Steam to install \(gameInfo.title)"))))
                        if run.claimStop() {
                            await stopSteam(client, prefix: prefix, signedIn: run.signedIn, keepSignIn: true)
                        }
                        try client.queueInstall(appID: steam.appID, installDir: steam.installDir)
                        try await client.start(silent: true)
                        run.started()
                        run.signedIn = try await signIn(client: client, prefix: prefix, input: input)
                        queued = true
                    }
                    try await waitForInstall(client: client, appID: steam.appID)
                    try linkInstalledGame(step, installDir: steam.installDir, wrappPath: wrappPath)
                case ("steam", "SIGN-OUT"):
                    if run.claimStop() {
                        await stopSteam(client, prefix: prefix, signedIn: run.signedIn)
                    }
                    let clientCache = self.clientCache
                    await Blocking.run { clientCache.save(from: prefix) }
                    // Nothing from here on uses Steam or its sign-in. Holding the lock
                    // through patching and saving had a wrapp opened as the build
                    // finished (or from its done screen) find Steam taken by the build.
                    lock.release()
                case ("steam", "REMOVE"):
                    try await removeSteam(from: wrappPath, keeping: plan)
                case (nil, "EDIT") where step.option("from-data") == "ini":
                    guard let files = step.arguments.first, let folder = WrappLayout(app: wrappPath).location(files)?.deletingLastPathComponent() else {
                        throw WrappBuildError.buildRecipeProblem("\(step.origin): EDIT's files aren't in the app")
                    }
                    try helper.configureGameINI(in: folder)
                case _ where WineSteps.handles(step):
                    try await preparer.run(step, in: wrappPath)
                case _ where WrappBuildHelper.isAppStep(step):
                    continue  // after the steps that put things in the prefix
                default:
                    throw WrappBuildError.buildRecipeProblem("\(step.origin): this build can't run \(step)")
                }
            }
            try await helper.runAppSteps(plan, wrappPath: wrappPath, gameInfo: gameInfo) { _ in nil }

            // What the game is, as the build's events and the legacy settings say it.
            let runsWithoutSteam = !composition.has(.steam)
            let gameExePath = composition.launcher == .scummvm ? "/SharedSupport/game"
                : drivePath(launch.options["steam.exe"] ?? launch.program)
            if composition.launcher != .scummvm {
                await bus.publishWrappBuild(.gameExeDetected(path: gameExePath, gameInfo: gameInfo))
            }
            try await helper.installMissingEngines(at: wrappPath, composition: composition)
            try await helper.cleanupUnusedEngine(at: wrappPath, composition: composition)

            let finalPath = try await helper.completeBuild(
                wrapp: wrappPath, gameInfo: gameInfo, source: .steam,
                gameExePath: gameExePath, installerDir: (gameExePath as NSString).deletingLastPathComponent,
                steamID: runsWithoutSteam ? nil : String(steam.appID), composition: composition,
                steamLaunchMode: launchMode, configureINI: false, edition: "steam",
                launch: launch, icon: plan.icon, input: input
            )
            await helper.launchIfAsked(finalPath, input: input)
            return finalPath
        } catch {
            if run.claimStop() {
                await stopSteam(client, prefix: prefix, signedIn: run.signedIn)
            }
            await helper.removeTempWrapp(wrappPath)

            let buildError = WrappBuildError(error)
            await bus.publishWrappBuild(.failed(buildError))
            throw error
        }
    }

    // MARK: - Steps

    /// What Steam needs to install `game`: its app and the folder Steam
    /// puts it in, under `steamapps/common/`.
    private static func steamData(_ game: GameInfo) -> (appID: Int, installDir: String)? {
        guard let appID = game.steamAppID, let installDir = game.steamInstallDir else { return nil }
        return (appID, installDir)
    }

    /// The steam module's `client` stage, as the app's modules plan it.
    nonisolated static func clientStage(in bundle: Bundle = .main) async throws -> PlannedStage {
        guard let resources = bundle.resourceURL else { throw WrappBuildError.templateDamaged("Second Chance has no resources") }
        return try await Blocking.run {
            let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules")).loadAll().get()
            guard let stage = try BuildPlanner.moduleStage("steam", "client", constraint: nil, modules: modules) else {
                throw WrappBuildError.buildRecipeProblem("the steam module has no client stage")
            }
            return stage
        }
    }

    /// A Wine program as a path from the root of C: (`/Nancy Drew/Game.exe`),
    /// as the legacy settings say it.
    private func drivePath(_ program: String) -> String {
        program.hasPrefix("wine:C:") ? String(program.dropFirst("wine:C:".count)) : program
    }

    /// `STEAM.INSTALL --into`: a link to the folder Steam installed the game
    /// in, so every later step, and the launch, name the game where the
    /// bundle says.
    private func linkInstalledGame(_ step: PlannedStep, installDir: String, wrappPath: URL) throws {
        let layout = WrappLayout(app: wrappPath)
        let steamGameDir = layout.prefix.appendingPathComponent(SteamClient.steamDirInPrefix)
            .appendingPathComponent("steamapps/common").appendingPathComponent(installDir)
        guard let into = step.option("into"), let link = layout.location(into) else {
            throw WrappBuildError.buildRecipeProblem("\(step.origin): STEAM.INSTALL's --into isn't in the app")
        }
        guard FileManager.default.fileExists(atPath: steamGameDir.path) else {
            logger.critical("Steam finished, but there's no \(steamGameDir.path)")
            throw WrappBuildError.gameExecutableNotFound
        }
        guard !FileManager.default.fileExists(atPath: link.path) else {
            throw WrappBuildError.buildRecipeProblem("\(step.origin): \(into) is there already")
        }
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: GameInstallerRunner.relativePath(from: link.deletingLastPathComponent(), to: steamGameDir))
        logger.notice("Steam installed the game in \(steamGameDir.path); \(into) links to it")
    }

    /// What the progress screen says while Steam wants a sign-in.
    static let signInInstructions = "Steam opens in its own window. Sign in there, or scan its QR code with the Steam app on your phone. "
        + "You'll stay signed in for your other Nancy Drew games, until you sign out "
        + "by choosing Sign Out of Steam from the Second Chance menu in the menu bar at the top of the screen."

    /// Wait for Steam to sign in, asking the user when it shows its
    /// sign-in window, and saying meanwhile whether it's updating itself or
    /// connecting (`SteamStartupWatch`). True once signed in.
    ///
    /// A Steam that exits first is started once more: its first start
    /// updates it, and one that crashed part-way through the download sat
    /// for the whole timeout before, then updated and signed in on the next
    /// build. Exiting again fails the build.
    ///
    /// Steam slow or stuck signing in is handled as `SteamStallPolicy`
    /// decides, its notices shown on the progress screen
    /// (`.steamSignInNotice`). Taking up its offer to sign in afresh signs
    /// out of Steam, takes the sign-in out of the prefix, and starts Steam
    /// again to ask for one. A Steam that keeps writing but neither signs in
    /// nor asks within `startTimeout` fails too.
    private func signIn(client: SteamClientDriving, prefix: URL, input: WrappBuildInput) async throws -> Bool {
        var deadline = Date().addingTimeInterval(Self.startTimeout)
        var restarted = false
        var policy = SteamStallPolicy(canOfferFreshSignIn: input.canSignInToSteam)
        var watch = SteamSignInWatch(client: client, exitedChecks: steamExitedChecks, quietLimit: signInQuietLimit)
        func startAgain(_ substep: String) async throws {
            await bus.publishWrappBuild(.progress(.installingGame(substep: substep)))
            await client.shutdown(timeout: 30)
            watch.restarted()
            try await client.start(silent: true)
            deadline = Date().addingTimeInterval(Self.startTimeout)
        }
        func carryOut(_ actions: [SteamStallPolicy.Action]) async throws {
            for action in actions {
                switch action {
                case .notice(let notice):
                    await bus.publishWrappBuild(.steamSignInNotice(notice))
                    // As long as someone signing in gets, once it's up to them.
                    if notice == .stuck { deadline = Date().addingTimeInterval(Self.signInTimeout) }
                case .restart:
                    logger.warning("Steam got stuck signing in; starting it again")
                    try await startAgain("Steam got stuck, so it's being started again")
                case .fail:
                    throw WrappBuildError.steamStoppedResponding
                }
            }
        }
        while Date() < deadline {
            if policy.notice == .stuck, input.takeSteamSignInAfreshRequest() {
                logger.notice("Signing out of Steam and starting it again, as the person asked")
                try await carryOut(policy.signingInAfresh())
                await client.shutdown(timeout: 30)
                do {
                    try sessionStore.signOut()
                } catch {
                    logger.error("Couldn't sign out of Steam: \(error)")
                }
                SteamSessionStore.strip(from: prefix)
                try await startAgain(SteamStartupStage.starting.message)
            }
            for event in watch.check() {
                try await carryOut(policy.handle(event))
                switch event {
                case .signedIn:
                    return true
                case .needsSignIn:
                    guard input.canSignInToSteam else { throw WrappBuildError.steamSignInRequired }
                    await bus.publishWrappBuild(.progress(.installingGame(substep: String(localized: "Waiting for you to sign in to Steam"))))
                    // Told to sign in in Steam's window once it's there: this
                    // waits for it to appear (up to a minute) and brings it forward.
                    await client.bringSignInWindowForward()
                    await bus.publishWrappBuild(.instructions(Self.signInInstructions))
                    deadline = Date().addingTimeInterval(Self.signInTimeout)
                case .startup(let stage):
                    await bus.publishWrappBuild(.progress(.installingGame(substep: stage.message)))
                    if let download = stage.download, let text = stage.downloadText {
                        await bus.publishWrappBuild(.stepProgress(StepProgress(
                            fraction: Double(download.doneKB) / Double(download.totalKB), text: text)))
                    }
                case .quiet, .active, .stuck:
                    break
                case .exited:
                    guard !restarted else {
                        logger.error("Steam exited again before it signed in")
                        throw WrappBuildError.steamExited
                    }
                    logger.warning("Steam exited before it signed in; starting it again")
                    restarted = true
                    watch.restarted()
                    await bus.publishWrappBuild(.progress(.installingGame(substep: SteamStartupStage.starting.message)))
                    try await client.start(silent: true)
                    if !watch.askedForSignIn { deadline = Date().addingTimeInterval(Self.startTimeout) }
                }
            }
            try await Task.sleep(for: signInPollInterval)
        }
        try await carryOut([.notice(nil)])
        if watch.askedForSignIn {
            logger.warning("Nobody signed in to Steam within \(Int(Self.signInTimeout))s")
            throw WrappBuildError.steamSignInTimedOut
        }
        logger.warning("Steam neither signed in nor asked for credentials in time")
        throw WrappBuildError.steamStoppedResponding
    }

    /// Wait for Steam to install the game, showing how far its download has
    /// got (`SteamDownloadMeter`). A Steam that exits — missing from
    /// `steamExitedChecks` checks in a row, as for the sign-in — fails the
    /// build: it would otherwise sit out the whole timeout for a Steam that
    /// was gone. A download that stops getting anywhere is told to the
    /// person after `downloadStallNote`, and fails the build after
    /// `downloadStallLimit`.
    private func waitForInstall(client: SteamClientDriving, appID: Int) async throws {
        let deadline = Date().addingTimeInterval(Self.installTimeout)
        var lastSubstep = ""
        var missingChecks = 0
        var meter: SteamDownloadMeter?
        var meterUnavailable = false
        var loggedTenth = -1
        var stalled = false
        while Date() < deadline {
            let phase = client.installPhase(appID: appID)
            switch phase {
            case .installed:
                if client.manifest(appID: appID)?.isFullyInstalled != false {
                    if stalled { await bus.publishWrappBuild(.instructions(nil)) }
                    return
                }
            case .failed(let reason) where reason == "Not enough disk space":
                throw WrappBuildError.notEnoughSpace(needed: nil, available: nil)
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

            // ── The download's progress ────────────────────────────────
            if case .updating(let name, let total?) = phase, Self.downloadPhases.contains(name), !meterUnavailable {
                if let count = await networkCounter.bytesReceived() {
                    let now = Date()
                    if meter == nil {
                        logger.notice("Steam is downloading \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)); measuring it by Wine's network traffic")
                        meter = SteamDownloadMeter(total: total, now: now)
                    }
                    meter?.add(count, at: now)
                    if let meter {
                        await bus.publishWrappBuild(.stepProgress(StepProgress(fraction: meter.fraction, text: meter.text(now: now))))
                        let tenth = Int(meter.fraction * 10)
                        if tenth > loggedTenth {
                            loggedTenth = tenth
                            logger.notice("[Steam] Downloaded \(meter.text(now: now))")
                        }
                        let quiet = meter.quietFor(now: now)
                        // The person is always told before the build gives
                        // up, even when one check finds it past both: a Mac
                        // asleep mid-download wakes to the note, not a failure.
                        if quiet >= downloadStallNote, !stalled {
                            stalled = true
                            logger.warning("Steam's download has got nowhere for \(Int(quiet))s, at \(meter.text(now: now))")
                            await bus.publishWrappBuild(.instructions(Self.downloadStalledInstructions))
                        } else if quiet >= downloadStallLimit, stalled {
                            logger.error("Steam's download got nowhere for \(Int(quiet))s, at \(meter.text(now: now))")
                            throw WrappBuildError.steamDownloadStalled
                        } else if quiet < downloadStallNote, stalled {
                            stalled = false
                            logger.notice("Steam's download is moving again")
                            await bus.publishWrappBuild(.instructions(nil))
                        }
                    }
                } else {
                    // Phases only, as before there was a meter.
                    meterUnavailable = true
                    logger.warning("Can't read Wine's network traffic, so the download's progress won't show")
                }
            } else if meter != nil {
                // Past the download: checking and committing it are the
                // disk's work, with nothing to measure.
                meter = nil
                if stalled {
                    stalled = false
                    await bus.publishWrappBuild(.instructions(nil))
                }
            }

            missingChecks = client.isRunning() ? 0 : missingChecks + 1
            if missingChecks >= steamExitedChecks {
                logger.error("Steam exited while installing the game (\(substep))")
                throw WrappBuildError.steamExitedWhileInstalling
            }
            try await Task.sleep(for: installPollInterval)
        }
        throw WrappBuildError.steamInstallFailed(reason: "it was still going after \(Int(Self.installTimeout / 3600)) hours")
    }

    /// Steam's phases in which it is downloading.
    private static let downloadPhases: Set<String> = ["Downloading", "Staging"]

    /// What the progress screen says while Steam's download is stuck.
    static let downloadStalledInstructions = "Steam hasn't downloaded anything for a while. Check that this Mac is connected to the internet. "
        + "The download carries on by itself once it can."

    /// What the progress line says during an install: Steam's phase. How far
    /// the download has got goes beside it (`stepProgress`).
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

    /// `STEAM.REMOVE`: each link `STEAM.INSTALL` made replaced by the game
    /// itself, moved out of Steam's library, then the Steam client and the
    /// settings its client stage gave its programs taken out of the wrapp.
    private func removeSteam(from wrappPath: URL, keeping plan: BuildPlan) async throws {
        let layout = WrappLayout(app: wrappPath)
        let files = FileManager.default
        for install in plan.bundleSteps where install.module == "steam" && install.instruction == "INSTALL" {
            guard let into = install.option("into"), let link = layout.location(into),
                  let target = try? files.destinationOfSymbolicLink(atPath: link.path) else { continue }
            let gameDir = link.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
            try files.removeItem(at: link)
            try files.moveItem(at: gameDir, to: link)
            logger.notice("Moved the game out of Steam's library to \(into)")
        }
        for path in [SteamClient.steamDirInPrefix, "drive_c/Program Files (x86)/Common Files/Steam"] {
            let url = layout.prefix.appendingPathComponent(path)
            if files.fileExists(atPath: url.path) {
                try files.removeItem(at: url)
            }
        }
        // Each setting the client stage made, removed as WINE.REGISTRY --remove would.
        for step in try await Self.clientStage().steps where step.module == "wine" && step.instruction == "REGISTRY" && step.has("set") {
            guard let target = step.arguments.first else { continue }
            try await preparer.run(PlannedStep(instruction: "REGISTRY", module: "wine", options: ["remove": [""]], arguments: [target],
                                               name: nil, origin: "STEAM.REMOVE, undoing \(step.origin)"), in: wrappPath)
        }
        logger.notice("Removed the Steam client from the wrapp")
    }
}
