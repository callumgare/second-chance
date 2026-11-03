//
//  BigFishWrappBuilder.swift
//  SecondChance
//
//  The per-source orchestrator for building a wrapp from a Big Fish Games
//  purchase.
//
//  The big-fish module's manager stage installs Big Fish's own Game Manager
//  in the wrapp's Wine prefix, and it's started; the person signs in in its
//  window and picks one of their games, and the game's Big Fish edition's
//  steps have the Game Manager download, install and activate it
//  (`BIG-FISH.INSTALL`), then sign the person out (`BIG-FISH.SIGN-OUT`). The
//  Game Manager stays in the wrapp: its services start the game.
//  docs/big-fish.md has why each step is as it is.
//

import Foundation
import Logging
import SecondChanceKit
import GameCatalog
import WrappBuilder
import WrappFormat

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.BigFishWrappBuilder")

/// One edition of a game the Big Fish account owns: the game, and which of
/// its language editions it is.
struct BigFishGameChoice: Equatable {
    let game: GameInfo
    let sku: BigFishSKU

    /// What the game picker shows: the title, and the language for an
    /// edition that isn't English.
    var displayName: String {
        switch sku.language {
        case BigFishSKU.english: return game.title
        case 2: return String(localized: "\(game.title) (in German)")
        case 4: return String(localized: "\(game.title) (in French)")
        default: return String(localized: "\(game.title) (in another language)")
        }
    }

    /// The editions in `owned` that are Nancy Drew games the catalog knows,
    /// in the order the games came out, English first within a game.
    static func choices(from owned: [BigFishOwnedGame], provider: GameInfoProvider) -> [BigFishGameChoice] {
        let order = Dictionary(provider.allGames().enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<BigFishSKU>()
        let choices = owned.compactMap { item -> BigFishGameChoice? in
            guard let sku = item.parsedSKU, sku.platform == BigFishSKU.windows, seen.insert(sku).inserted,
                  let game = provider.game(forBigFish: sku) else { return nil }
            return BigFishGameChoice(game: game, sku: sku)
        }
        return choices.sorted { left, right in
            let (leftIndex, rightIndex) = (order[left.game.id] ?? .max, order[right.game.id] ?? .max)
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            let (leftEnglish, rightEnglish) = (left.sku.language == BigFishSKU.english, right.sku.language == BigFishSKU.english)
            if leftEnglish != rightEnglish { return leftEnglish }
            return left.sku.language < right.sku.language
        }
    }
}

/// The parts of a Big Fish build that need Wine: making the wrapp with the
/// Game Manager installed in it, and cancelling the DirectX setup a game's
/// installer starts. Tests stand in a fake.
protocol BigFishWrappPreparing {
    /// The template, a Wine prefix and the Game Manager, installed and not
    /// running: the big-fish module's `manager` stage.
    func prepare(wrappAt path: URL) async throws
    /// One of the Wine steps a game's Big Fish stage has of its own
    /// (cnc-ddraw's), carried out in the wrapp's prefix.
    func run(_ step: PlannedStep, in path: URL) async throws
    /// Start dismissing Microsoft's DirectX web setup, which a game's
    /// installer runs and the games don't need, until `stopCancellingDirectXSetup`.
    func startCancellingDirectXSetup(in path: URL) async
    /// Stop that, and take what it put in the prefix out again. Safe to call
    /// when it was never started.
    func stopCancellingDirectXSetup(in path: URL) async
    /// Take the account out of the prefix once the Game Manager has stopped:
    /// signing out leaves its tokens and email in the registry, and the store's
    /// session cookies in the Game Manager's browser profile.
    func forgetAccount(in path: URL) async throws
    /// Put the sign-in kept from an earlier build into the prefix, before the
    /// Game Manager starts. False when none is kept.
    func restoreSignIn(into path: URL) async -> Bool
    /// Keep the Game Manager's sign-in for the next build, once it has
    /// stopped (`BigFishSessionStore`).
    func keepSignIn(from path: URL) async
}

/// The real `BigFishWrappPreparing`: Big Fish's installer, clicked through
/// with AutoIt.
final class BigFishWrappPreparer: BigFishWrappPreparing {
    /// It's about 144 MB: anything much smaller is an error page.
    nonisolated static let installerMinimumSize = 50_000_000
    static let setupScript = "big-fish-game-manager-setup"
    static let directXScript = "big-fish-directx-cancel"
    /// Where the AutoIt scripts, AutoIt and the installer are put while they
    /// run, under the prefix's C: drive.
    static let stagingFolder = "second-chance-big-fish"
    static let installTimeout: TimeInterval = 30 * 60

    private let helper: WrappBuildHelper
    private let bus: EventBus<AppEvent>
    private let sessionStore: BigFishSessionStore
    private let lock = NSLock()
    private var directXCanceller: WineProcess?

    init(helper: WrappBuildHelper, bus: EventBus<AppEvent>, sessionStore: BigFishSessionStore = BigFishSessionStore()) {
        self.helper = helper
        self.bus = bus
        self.sessionStore = sessionStore
    }

    func run(_ step: PlannedStep, in path: URL) async throws {
        try await WineSteps(bus: bus).run(step, wrappPath: path)
    }

    /// The template and the wine module's prefix, then the big-fish
    /// module's `manager` stage's steps (`FROM big-fish@1/manager`): the
    /// Game Manager installed, and ⌘ acting as Ctrl in its window.
    func prepare(wrappAt path: URL) async throws {
        try await helper.createBaseWrapp(at: path)
        for step in try await BigFishWrappBuilder.managerStage().steps {
            switch (step.module, step.instruction) {
            case ("big-fish", "MANAGER"):
                let (url, sha256) = try Self.installerFetch(of: step)
                await bus.publishWrappBuild(.progress(.settingUpWrapp(substep: String(localized: "Installing Big Fish's Game Manager"))))
                do {
                    try await installGameManager(from: url, sha256: sha256, in: path)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.error("Couldn't install the Game Manager: \(ErrorChain.describe(error))")
                    let buildError = WrappBuildError(error)
                    if case .internalError = buildError { throw WrappBuildError.bigFishGameManagerInstallFailed }
                    throw buildError
                }
            case _ where WineSteps.handles(step):
                try await run(step, in: path)
            default:
                throw WrappBuildError.buildRecipeProblem("\(step.origin): this build can't run \(step)")
            }
        }
    }

    /// Run Big Fish's installer through `big-fish-game-manager-setup.au3`.
    /// Its `/S` doesn't make it silent: it relaunches itself to ask for
    /// administrator rights, and the relaunch stops on its licence page, so
    /// the script clicks through it. The installer starts the Game Manager
    /// as it finishes, and only one runs in a prefix, so the session is
    /// ended afterwards for the build to start its own.
    private func installGameManager(from url: URL, sha256: String, in path: URL) async throws {
        let installer = try await Self.gameManagerInstaller(from: url, sha256: sha256)
        let layout = WrappLayout(app: path)
        let wine = Wine(wrapp: path)
        let staging = try await stage(script: Self.setupScript, in: layout.driveC)
        defer { removeStaging(in: layout.driveC) }
        let installerCopy = staging.appendingPathComponent("bfginstaller35.exe")
        try await Blocking.run { try FileManager.default.copyItem(at: installer, to: installerCopy) }
        let client = layout.prefix.appendingPathComponent(BigFishGameManager.clientDirInPrefix).appendingPathComponent("bfgclient.exe")

        func windows(_ url: URL) -> String { GameInstallerRunner.windowsPath(of: url, driveC: layout.driveC) }
        await wine.server.stop()
        // The installer runs Big Fish's epoch.exe, which searches every drive,
        // folder by folder, for a file a Big Fish CD would have: through a
        // drive showing the whole Mac that took hours. The prefix has none
        // (WineDrives), so it searches only C:.
        let desktop = await WineDesktop.start(wine, logger: logger, outputLogger: wineOutputLogger)
        do {
            // /ErrorStdOut: a script error is logged, not shown in a box nobody closes.
            // Nothing of it is seen, the script's clicks included, nor of the
            // Game Manager it starts as it finishes (hidden_windows.m): its
            // file to show them is never made.
            let neverShown = FileManager.default.temporaryDirectory.appendingPathComponent("second-chance-never-shown")
            try await wine.run(.program(windows(staging.appendingPathComponent("autoit/AutoIt3.exe")), [
                "/ErrorStdOut", windows(staging.appendingPathComponent("\(Self.setupScript).au3")),
                windows(installerCopy), windows(client),
            ]), environment: Wine.hiddenWindowsVariables(exe: "*", showFile: neverShown), timeout: Self.installTimeout)
        } catch {
            desktop?.release()
            await endSession(wine)
            throw error
        }
        desktop?.release()
        await endSession(wine)
        guard FileManager.default.fileExists(atPath: client.path) else {
            throw WrappBuildError.internalError("Big Fish's installer finished, but there's no \(client.path)")
        }
        logger.notice("Installed the Game Manager")
    }

    /// The Game Manager's sign-in, as it keeps it in the registry.
    /// Its browser profile: cookies (the store's session among them) and caches.
    static let browserProfile = "drive_c/ProgramData/Big Fish/cef"

    func forgetAccount(in path: URL) async throws {
        let layout = WrappLayout(app: path)
        let profile = layout.prefix.appendingPathComponent(Self.browserProfile)
        try await Blocking.run {
            if FileManager.default.fileExists(atPath: profile.path) { try FileManager.default.removeItem(at: profile) }
        }
        let wine = Wine(wrapp: path)
        for name in BigFishGameManager.accountValues {
            try await wine.registry.deleteValue(name, in: BigFishGameManager.accountKey)
        }
        await endSession(wine)
        logger.notice("Took the Big Fish account out of the prefix: its registry values and the Game Manager's browser profile")
    }

    func restoreSignIn(into path: URL) async -> Bool {
        let layout = WrappLayout(app: path)
        let wine = Wine(wrapp: path)
        do {
            guard let fragment = try sessionStore.restore(into: layout.prefix) else { return false }
            defer { BigFishSessionStore.removeFragment(from: layout.prefix) }
            try await wine.run(.wine(["reg", "import", fragment]), timeout: 120)
            await endSession(wine)
            logger.notice("Put the kept Big Fish sign-in into the prefix")
            return true
        } catch {
            // Not a failure: the person is asked to sign in instead.
            logger.warning("Couldn't put the kept Big Fish sign-in into the prefix: \(ErrorChain.describe(error))")
            return false
        }
    }

    func keepSignIn(from path: URL) async {
        let prefix = WrappLayout(app: path).prefix
        let store = sessionStore
        do {
            _ = try await Blocking.run { try store.capture(from: prefix) }
        } catch {
            logger.warning("Couldn't keep the Big Fish sign-in for the next build: \(ErrorChain.describe(error))")
        }
    }

    /// End the prefix's Wine session, and the Game Manager the installer started with it.
    private func endSession(_ wine: Wine) async {
        await wine.server.stop()
        if await !wine.server.waitUntilStopped(timeout: 60) {
            logger.warning("Wine was still running 60s after being asked to stop; killing it")
            await wine.server.kill()
        }
    }

    /// `BIG-FISH.MANAGER`'s installer: its `fetch` mount's address and hash.
    nonisolated static func installerFetch(of step: PlannedStep) throws -> (url: URL, sha256: String) {
        guard let fetch = (step.options["mount"] ?? []).map(GameInstallerRunner.fields(of:)).first(where: { $0["type"] == "fetch" }),
              let url = fetch["url"].flatMap(URL.init(string:)), let sha256 = fetch["sha256"] else {
            throw WrappBuildError.buildRecipeProblem("\(step.origin): BIG-FISH.MANAGER needs its installer as a fetch mount with its sha256")
        }
        return (url, sha256)
    }

    /// The installer the manager stage pins, downloaded once into the caches
    /// directory: what the integration tests fetch before their builds.
    static func gameManagerInstaller() async throws -> URL {
        guard let step = try await BigFishWrappBuilder.managerStage().steps.first(where: { $0.module == "big-fish" && $0.instruction == "MANAGER" }) else {
            throw WrappBuildError.buildRecipeProblem("the big-fish module's manager stage installs no Game Manager")
        }
        let (url, sha256) = try installerFetch(of: step)
        return try await gameManagerInstaller(from: url, sha256: sha256)
    }

    /// Big Fish's installer, downloaded once into the caches directory, and
    /// only used when its hash is the one the manager stage pins.
    static func gameManagerInstaller(from url: URL, sha256: String) async throws -> URL {
        let cached = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecondChance/bfginstaller35.exe")
        if await Blocking.run({ isUsableInstaller(cached, sha256: sha256) }) { return cached }
        logger.notice("Downloading the Game Manager's installer from \(url.absoluteString)")
        let (download, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw WrappBuildError.internalError("Couldn't download the Game Manager's installer (HTTP \(status))")
        }
        guard await Blocking.run({ isUsableInstaller(download, sha256: sha256) }) else {
            throw WrappBuildError.internalError(
                "The Game Manager's installer that downloaded isn't the one the big-fish module's manager stage names (sha256 \(sha256)): "
                + "Big Fish may have updated it, which needs the stage updating")
        }
        try await Blocking.run {
            try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: cached.path) { try FileManager.default.removeItem(at: cached) }
            try FileManager.default.moveItem(at: download, to: cached)
        }
        return cached
    }

    /// The installer the stage pins: a file of about the installer's size
    /// (anything much smaller is an error page) with its sha256.
    nonisolated static func isUsableInstaller(_ url: URL, sha256: String) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size >= installerMinimumSize else { return false }
        return (try? LayerKey.hash(file: url)) == sha256.lowercased()
    }

    func startCancellingDirectXSetup(in path: URL) async {
        let driveC = WrappLayout(app: path).driveC
        do {
            let staging = try await stage(script: Self.directXScript, in: driveC)
            func windows(_ url: URL) -> String { GameInstallerRunner.windowsPath(of: url, driveC: driveC) }
            let process = try Wine(wrapp: path).start(.program(windows(staging.appendingPathComponent("autoit/AutoIt3.exe")), [
                "/ErrorStdOut", windows(staging.appendingPathComponent("\(Self.directXScript).au3")),
            ]), output: .log(wineOutputLogger))
            lock.withLock { directXCanceller = process }
            logger.notice("Watching for DirectX's setup, to cancel it")
        } catch {
            logger.warning("Couldn't start cancelling DirectX's setup, so the game's install may wait on it: \(ErrorChain.describe(error))")
        }
    }

    func stopCancellingDirectXSetup(in path: URL) async {
        guard let process = lock.withLock({ () -> WineProcess? in
            defer { directXCanceller = nil }
            return directXCanceller
        }) else { return }
        if process.isRunning { process.terminate() }
        removeStaging(in: WrappLayout(app: path).driveC)
    }

    /// Copy AutoIt and a script into the prefix; the folder they're in.
    private func stage(script: String, in driveC: URL) async throws -> URL {
        guard AutoItService.shared.isAvailable else { throw WrappBuildError.autoItNotAvailable }
        guard let source = Bundle.main.url(forResource: script, withExtension: "au3") else {
            throw WrappBuildError.autoItScriptNotFound
        }
        let staging = driveC.appendingPathComponent(Self.stagingFolder)
        let autoIt = AutoItService.shared.autoitDir
        try await Blocking.run {
            let files = FileManager.default
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            let autoItCopy = staging.appendingPathComponent("autoit")
            if !files.fileExists(atPath: autoItCopy.path) { try files.copyItem(at: autoIt, to: autoItCopy) }
            let scriptCopy = staging.appendingPathComponent("\(script).au3")
            if files.fileExists(atPath: scriptCopy.path) { try files.removeItem(at: scriptCopy) }
            try files.copyItem(at: source, to: scriptCopy)
        }
        return staging
    }

    /// Take AutoIt and its scripts out of the prefix, so the wrapp doesn't ship them.
    private func removeStaging(in driveC: URL) {
        let staging = driveC.appendingPathComponent(Self.stagingFolder)
        guard FileManager.default.fileExists(atPath: staging.path) else { return }
        do {
            try FileManager.default.removeItem(at: staging)
        } catch {
            logger.warning("Couldn't remove \(Self.stagingFolder) from the prefix: \(error.localizedDescription)")
        }
    }
}

/// Builds a wrapp from a game in the person's Big Fish Games library.
final class BigFishWrappBuilder: WrappBuildStrategy {
    private let helper: WrappBuildHelper
    private let installerRunner: GameInstallerRunner
    private let gameInfoProvider: GameInfoProvider
    private let makeManager: (URL) -> BigFishGameManaging
    private let preparer: BigFishWrappPreparing
    private let signInPollInterval: Duration
    private let installPollInterval: Duration
    /// How many looks in a row must find the Game Manager missing before it
    /// counts as having quit.
    private let managerExitedChecks: Int
    /// How long a person gets to sign in.
    private let signInTimeout: TimeInterval
    let bus: EventBus<AppEvent>

    /// Its first start sets itself up, which takes a while under Wine.
    static let startTimeout: TimeInterval = 10 * 60
    /// A whole download, for the slowest connection worth waiting on.
    static let installTimeout: TimeInterval = 4 * 60 * 60
    /// How long the test harness's sign-in may take to go through.
    static let testSignInTimeout: TimeInterval = 2 * 60
    static let shutdownTimeout: TimeInterval = 60
    /// How many looks in a row may fail to read the Game Manager's progress
    /// before the build gives up on it.
    static let statusFailureLimit = 15

    init(
        helper: WrappBuildHelper = .shared,
        installerRunner: GameInstallerRunner = .shared,
        gameInfoProvider: GameInfoProvider = .shared,
        makeManager: ((URL) -> BigFishGameManaging)? = nil,
        preparer: BigFishWrappPreparing? = nil,
        signInPollInterval: Duration = .seconds(2),
        installPollInterval: Duration = .seconds(2),
        managerExitedChecks: Int = 3,
        signInTimeout: TimeInterval = 30 * 60,
        bus: EventBus<AppEvent> = .app
    ) {
        self.helper = helper
        self.installerRunner = installerRunner
        self.gameInfoProvider = gameInfoProvider
        self.makeManager = makeManager ?? { BigFishGameManager(wrappPath: $0) }
        self.preparer = preparer ?? BigFishWrappPreparer(helper: helper, bus: bus)
        self.signInPollInterval = signInPollInterval
        self.installPollInterval = installPollInterval
        self.managerExitedChecks = managerExitedChecks
        self.signInTimeout = signInTimeout
        self.bus = bus
    }

    /// What the progress screen says while the Game Manager waits for a sign-in.
    static let signInInstructions = String(localized: """
        Big Fish's Game Manager has opened in its own window. Sign in there with your Big Fish Games account, \
        and installing carries on by itself. Second Chance remembers your sign-in for the next game, \
        but the game's app never keeps it.
        """)

    func build(input: WrappBuildInput) async throws -> URL {
        await bus.publishWrappBuild(.started(source: .bigFish))

        let trial = input.isBigFishTrial
        let preselected: GameInfo?
        do {
            preselected = try input.bigFishGameFromEnvironment(among: gameInfoProvider.allGames())
            if trial && preselected == nil { throw WrappBuildError.missingRequiredParameter("BIG_FISH_GAME_SLUG") }
        } catch {
            await bus.publishWrappBuild(.failed(WrappBuildError(error)))
            throw error
        }

        let wrappPath = helper.createTemporaryWrappPath()
        logger.notice("Temporary wrapp: \(wrappPath.path)")
        let manager = makeManager(wrappPath)
        var managerStarted = false
        // A person's sign-in is kept for the next build, and the one kept from
        // the last is used; never the test harness's, nor for a trial.
        let usesKeptSignIn = !trial && input.bigFishTestSignIn == nil
        var keepsSignIn = false

        do {
            try await preparer.prepare(wrappAt: wrappPath)
            if usesKeptSignIn, await preparer.restoreSignIn(into: wrappPath) {
                logger.notice("Starting the Game Manager with the sign-in kept from an earlier build")
            }

            await bus.publishWrappBuild(.progress(.installingGame(substep: String(localized: "Starting Big Fish's Game Manager"))))
            managerStarted = true
            try await manager.start(timeout: Self.startTimeout)

            // ── Sign in and pick the game ──────────────────────────────
            let choice: BigFishGameChoice
            if trial, let preselected {
                guard let product = preselected.bigFishProduct else {
                    throw WrappBuildError.internalError("\(preselected.title) has no Big Fish product")
                }
                choice = BigFishGameChoice(game: preselected, sku: BigFishSKU(product: product))
            } else {
                try await signIn(manager, input: input)
                keepsSignIn = usesKeptSignIn
                choice = try await pickGame(manager, preselected: preselected, input: input)
            }
            let gameInfo = choice.game
            await bus.publishWrappBuild(.gameDetected(gameInfo))
            try await input.onGameDetected(gameInfo)
            // The game's Big Fish edition: Big Fish's DRM starts a Wine game;
            // ScummVM runs nothing of Big Fish's.
            let slug = gameInfo.id
            let plan = try await Blocking.run { try ShippedBundles.plan(forGame: slug, edition: "big-fish") }
            guard let plan, let launch = plan.launch else {
                throw WrappBuildError.buildRecipeProblem("\(gameInfo.id)'s Big Fish edition has no stage")
            }
            let composition = Composition(launch: launch)
            await bus.publishWrappBuild(.engineRouted(composition: composition, gameInfo: gameInfo))
            logger.notice("Building \(gameInfo.title) from Big Fish (\(choice.sku)\(trial ? ", free trial" : "")), engine \(composition.engineTag)")

            for step in plan.bundleSteps {
                logger.debug("Plan step: \(step) (\(step.origin))")
                switch (step.module, step.instruction) {
                case ("big-fish", "INSTALL"):
                    // ── Download, install and activate ─────────────────
                    if step.has("decline-directx") { await preparer.startCancellingDirectXSetup(in: wrappPath) }
                    try await manager.download(choice.sku, fullVersion: !trial)
                    let installed = try await waitForInstall(manager, sku: choice.sku)
                    await preparer.stopCancellingDirectXSetup(in: wrappPath)
                    try linkInstalledGame(step, folder: installed.folder, wrappPath: wrappPath)
                case ("big-fish", "SIGN-OUT"):
                    // The sign-in mustn't ship in the app: anyone given a copy could
                    // use the account. An activated game plays signed out. A person's
                    // is kept for the next build instead (signing out may end it with
                    // Big Fish too); the test harness's is signed out.
                    if !trial && !keepsSignIn { try await signOut(manager) }
                    await bus.publishWrappBuild(.progress(.installingGame(substep: String(localized: "Closing Big Fish's Game Manager"))))
                    await manager.shutdown(timeout: Self.shutdownTimeout)
                    managerStarted = false
                    if keepsSignIn { await preparer.keepSignIn(from: wrappPath) }
                    // Signing out leaves the account's tokens in the registry and the
                    // store's session in the Game Manager's browser profile.
                    try await preparer.forgetAccount(in: wrappPath)
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
            let runsInScummVM = composition.launcher == .scummvm
            func drivePath(_ program: String?) -> String? {
                program.flatMap { $0.split(separator: ":", maxSplits: 1).last.map { String($0.dropFirst(2)) } }
            }
            let gameExePath = runsInScummVM ? "/SharedSupport/game" : drivePath(launch.options["big-fish.exe"]) ?? ""
            if !runsInScummVM {
                await bus.publishWrappBuild(.gameExeDetected(path: gameExePath, gameInfo: gameInfo))
            }
            try await helper.installMissingEngines(at: wrappPath, composition: composition)
            try await helper.cleanupUnusedEngine(at: wrappPath, composition: composition)

            let finalPath = try await helper.completeBuild(
                wrapp: wrappPath, gameInfo: gameInfo, source: .bigFish,
                gameExePath: gameExePath, installerDir: (gameExePath as NSString).deletingLastPathComponent, composition: composition,
                bigFishLaunchFile: runsInScummVM ? nil : drivePath(launch.program), bigFishSKU: choice.sku.description,
                bigFishTrial: trial ? true : nil, configureINI: false, edition: "big-fish",
                launch: launch, icon: plan.icon, input: input
            )
            await helper.launchIfAsked(finalPath, input: input)
            return finalPath
        } catch {
            await preparer.stopCancellingDirectXSetup(in: wrappPath)
            if managerStarted { await manager.shutdown(timeout: Self.shutdownTimeout) }
            // So trying again needn't sign in again. Nothing, once the build
            // has taken the account out.
            if keepsSignIn { await preparer.keepSignIn(from: wrappPath) }
            await helper.removeTempWrapp(wrappPath)
            await bus.publishWrappBuild(.failed(WrappBuildError(error)))
            throw error
        }
    }

    // MARK: - Steps

    /// Get the Game Manager signed in: already, from an earlier start; with
    /// the test harness's account; or by the person, in its window.
    private func signIn(_ manager: BigFishGameManaging, input: WrappBuildInput) async throws {
        if try await manager.isSignedIn() {
            logger.notice("The Game Manager is already signed in")
            return
        }
        if let account = input.bigFishTestSignIn {
            logger.notice("Signing in to the Game Manager with the test harness's account")
            await bus.publishWrappBuild(.progress(.installingGame(substep: String(localized: "Signing in to Big Fish Games"))))
            try await manager.signInForTesting(email: account.email, password: account.password)
            guard try await waitForSignIn(manager, timeout: Self.testSignInTimeout) else {
                logger.error("The test harness's sign-in didn't go through")
                throw WrappBuildError.bigFishSignInRequired
            }
            return
        }
        guard input.canSignInToBigFish else { throw WrappBuildError.bigFishSignInRequired }
        await bus.publishWrappBuild(.progress(.installingGame(substep: String(localized: "Waiting for you to sign in to Big Fish Games"))))
        try await manager.showSignIn()
        await bus.publishWrappBuild(.instructions(Self.signInInstructions))
        let signedIn = try await waitForSignIn(manager, timeout: signInTimeout)
        manager.hideWindow()
        await bus.publishWrappBuild(.instructions(nil))
        guard signedIn else {
            logger.warning("Nobody signed in to the Game Manager within \(Int(signInTimeout))s")
            throw WrappBuildError.bigFishSignInTimedOut
        }
        logger.notice("Signed in to the Game Manager")
    }

    /// Whether the Game Manager signs in within `timeout`. Its page may
    /// reload as it does, so a look that can't read it is tried again.
    private func waitForSignIn(_ manager: BigFishGameManaging, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var missingChecks = 0
        while Date() < deadline {
            missingChecks = manager.isRunning() ? 0 : missingChecks + 1
            if missingChecks >= managerExitedChecks {
                logger.error("The Game Manager quit while waiting for a sign-in")
                throw WrappBuildError.bigFishGameManagerQuit
            }
            do {
                if try await manager.isSignedIn() { return true }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.debug("Couldn't read the Game Manager's sign-in: \(ErrorChain.describe(error))")
            }
            try await Task.sleep(for: signInPollInterval)
        }
        return false
    }

    /// The game to build: the one named up front, in English if the account
    /// has that edition; or the one the person picks from what it owns.
    private func pickGame(_ manager: BigFishGameManaging, preselected: GameInfo?,
                          input: WrappBuildInput) async throws -> BigFishGameChoice {
        await bus.publishWrappBuild(.progress(.installingGame(substep: String(localized: "Checking which games your Big Fish Games account has"))))
        let choices = BigFishGameChoice.choices(from: try await manager.ownedGames(), provider: gameInfoProvider)
        var games: [GameInfo] = []
        for choice in choices where !games.contains(where: { $0.id == choice.game.id }) { games.append(choice.game) }
        logger.notice("The Big Fish account owns \(choices.count) edition(s) of the games: \(choices.map { "\($0.game.id) (\($0.sku))" }.joined(separator: ", "))")
        await bus.publishWrappBuild(.bigFishGamesOwned(games))

        if let preselected {
            let editions = choices.filter { $0.game.id == preselected.id }
            guard let choice = editions.first(where: { $0.sku.language == BigFishSKU.english }) ?? editions.first else {
                throw WrappBuildError.bigFishGameNotOwned(title: preselected.title)
            }
            return choice
        }
        guard !choices.isEmpty else { throw WrappBuildError.bigFishNoGamesOwned }
        return try await input.chooseBigFishGame(from: choices)
    }

    /// Wait for the Game Manager to download, install and activate `sku`,
    /// saying which it's doing and how far the download has got.
    private func waitForInstall(_ manager: BigFishGameManaging, sku: BigFishSKU) async throws -> BigFishInstalledGame {
        let deadline = Date().addingTimeInterval(Self.installTimeout)
        var lastSubstep: String?
        var lastPercent: Int?
        var lastState: Int?
        var sawInstalling = false
        var missingChecks = 0
        var statusFailures = 0
        while Date() < deadline {
            missingChecks = manager.isRunning() ? 0 : missingChecks + 1
            if missingChecks >= managerExitedChecks {
                logger.error("The Game Manager quit while it was getting the game (\(lastSubstep ?? "before it started"))")
                throw WrappBuildError.bigFishGameManagerQuit
            }
            let status: BigFishGameStatus?
            do {
                status = try await manager.status(of: sku)
                statusFailures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                statusFailures += 1
                logger.warning("Couldn't read the Game Manager's progress (\(statusFailures) in a row): \(ErrorChain.describe(error))")
                if statusFailures >= Self.statusFailureLimit { throw error }
                try await Task.sleep(for: installPollInterval)
                continue
            }
            if let status, status.state != lastState {
                lastState = status.state
                logger.notice("The Game Manager's state for \(sku): \(status.state) (error code \(status.errorCode))")
            }
            let phase = status?.phase ?? .waiting
            switch phase {
            case .ready:
                if let installed = manager.installedGame(sku) {
                    logger.notice("\(sku) is installed and activated in \(installed.folder.path) (launcher \(installed.launcher))")
                    return installed
                }
            case .downloadFailed:
                throw WrappBuildError.bigFishDownloadFailed
            case .installFailed, .failed:
                throw WrappBuildError.bigFishInstallFailed
            case .activationFailed:
                throw WrappBuildError.bigFishActivationFailed
            case .installing, .activating:
                sawInstalling = true
            case .downloading, .waiting:
                break
            }
            let substep = Self.substep(for: phase, afterInstalling: sawInstalling)
            if substep != lastSubstep {
                lastSubstep = substep
                lastPercent = nil
                await bus.publishWrappBuild(.progress(.installingGame(substep: substep)))
            }
            if let fraction = Self.fraction(of: phase) {
                let percent = Int((fraction * 100).rounded(.down))
                if percent != lastPercent {
                    lastPercent = percent
                    await bus.publishWrappBuild(.stepProgress(StepProgress(fraction: fraction, text: String(localized: "\(percent)% done"))))
                }
            }
            try await Task.sleep(for: installPollInterval)
        }
        logger.error("The Game Manager was still getting \(sku) after \(Int(Self.installTimeout / 3600)) hours")
        throw WrappBuildError.bigFishDownloadFailed
    }

    /// What the progress line says while the Game Manager gets the game.
    /// Activation is mostly the install at 100% (`BigFishGameStatus.Phase`),
    /// but also the wait after installing, and a ready state before the
    /// game's folder has its `bfgstate.xml`.
    static func substep(for phase: BigFishGameStatus.Phase, afterInstalling: Bool) -> String {
        switch phase {
        case .downloading: return String(localized: "Downloading the game")
        case .installing: return String(localized: "Installing the game")
        case .activating, .ready: return String(localized: "Activating the game")
        case .waiting where afterInstalling: return String(localized: "Activating the game")
        default: return String(localized: "Waiting for the download to start")
        }
    }

    static func fraction(of phase: BigFishGameStatus.Phase) -> Double? {
        switch phase {
        case .downloading(let fraction), .installing(let fraction): return fraction
        default: return nil
        }
    }

    /// Sign the Game Manager out, and wait until it says it is.
    private func signOut(_ manager: BigFishGameManaging) async throws {
        try await manager.signOut()
        let deadline = Date().addingTimeInterval(30)
        while try await manager.isSignedIn() {
            guard Date() < deadline else {
                throw WrappBuildError.internalError("The Game Manager was still signed in 30s after signing out")
            }
            try await Task.sleep(for: signInPollInterval)
        }
    }

    /// The big-fish module's `manager` stage, as the app's modules plan it.
    nonisolated static func managerStage(in bundle: Bundle = .main) async throws -> PlannedStage {
        guard let resources = bundle.resourceURL else { throw WrappBuildError.templateDamaged("Second Chance has no resources") }
        return try await Blocking.run {
            let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules")).loadAll().get()
            guard let stage = try BuildPlanner.moduleStage("big-fish", "manager", constraint: nil, modules: modules) else {
                throw WrappBuildError.buildRecipeProblem("the big-fish module has no manager stage")
            }
            return stage
        }
    }

    /// `BIG-FISH.INSTALL --into`: a link to the folder the Game Manager
    /// installed the game in, so every later step, and the launch, name the
    /// game where the bundle says.
    private func linkInstalledGame(_ step: PlannedStep, folder: URL, wrappPath: URL) throws {
        guard let into = step.option("into"), let link = WrappLayout(app: wrappPath).location(into) else {
            throw WrappBuildError.buildRecipeProblem("\(step.origin): BIG-FISH.INSTALL's --into isn't in the app")
        }
        guard folder.standardizedFileURL != link.standardizedFileURL else { return }
        guard !FileManager.default.fileExists(atPath: link.path) else {
            throw WrappBuildError.buildRecipeProblem("\(step.origin): \(into) is there already")
        }
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: GameInstallerRunner.relativePath(from: link.deletingLastPathComponent(), to: folder))
        logger.notice("Big Fish installed the game in \(folder.path); \(into) links to it")
    }
}
