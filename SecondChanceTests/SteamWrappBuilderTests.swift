//
//  SteamWrappBuilderTests.swift
//  SecondChanceTests
//
//  The Steam build, end to end, with a fake Steam: what it publishes, what
//  ends up in the wrapp (and what must not), and how it fails.

import Foundation
import Testing
@testable import ProcessKit
@testable import SecondChance
@testable import SecondChanceKit
import WrappBuilder
import WrappFormat
@testable import WineKit
import GameCatalog

/// Steam as the builder sees it, without Wine. Its "install" puts the game's
/// exe where Steam would, and its shutdown leaves a sign-in behind in the
/// prefix, as a real Steam does, so the test can check it doesn't ship.
final class FakeSteamClient: SteamClientDriving, @unchecked Sendable {
    let prefix: URL
    var hasSession = true
    var login = SteamLogs.LoginState.signedIn
    var owned: Set<Int> = []
    var install = SteamLogs.InstallPhase.installed
    /// How many of its starts Steam exits after, before signing in.
    var exitsBeforeSignIn = 0
    /// How many sign-in checks find Steam still updating itself.
    var updatingChecks = 0
    /// Steam exits once the install has started, and never finishes it.
    var exitsWhileInstalling = false
    /// How many install checks find Steam still downloading a 1 MB game.
    var downloadingChecks = 0
    /// When Steam last wrote to its logs while it isn't updating itself;
    /// while it is, every check finds a new write.
    var logWrite: Date?
    private var starts = 0
    private(set) var calls: [String] = []
    private(set) var savedSignedIn: Bool?
    private var queued: (appID: Int, installDir: String)?
    private let lock = NSLock()

    init(wrappPath: URL) {
        prefix = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix")
    }

    private func record(_ call: String) { lock.withLock { calls.append(call) } }

    func restoreLogin(from store: SteamSessionStore) async throws -> Bool { record("restoreLogin"); return hasSession }
    func saveLogin(to store: SteamSessionStore, signedIn: Bool) throws -> SteamSessionStore.CaptureResult {
        record("saveLogin")
        savedSignedIn = signedIn
        return signedIn ? .saved : .notSignedIn
    }
    func queueInstall(appID: Int, installDir: String) throws { record("queueInstall \(appID)"); queued = (appID, installDir) }
    func start(silent: Bool) async throws {
        record("start")
        lock.withLock { starts += 1 }
    }
    func waitForLogin(timeout: TimeInterval) async -> SteamLogs.LoginState { loginState() }
    func loginState() -> SteamLogs.LoginState {
        guard isRunning() else { return .pending }
        return lock.withLock {
            guard updatingChecks == 0 else {
                updatingChecks -= 1
                return .pending
            }
            return login
        }
    }
    func bootstrapPhase() -> SteamLogs.BootstrapPhase {
        lock.withLock { updatingChecks > 0 ? .downloading(doneKB: 51_200, totalKB: 102_400) : .verified }
    }
    func isConnecting() -> Bool { false }
    func lastLogWrite() -> Date? { lock.withLock { updatingChecks > 0 ? Date() : logWrite } }
    func isRunning() -> Bool { lock.withLock { starts > exitsBeforeSignIn && !(exitsWhileInstalling && installing) } }
    private var installing = false
    /// The player signs in once the sign-in window is in front of them.
    func bringSignInWindowForward() async {
        record("bringSignInWindowForward")
        lock.withLock { login = .signedIn }
    }
    func ownedAppIDs(timeout: TimeInterval) async throws -> Set<Int> { owned }
    func installPhase(appID: Int) -> SteamLogs.InstallPhase {
        if exitsWhileInstalling {
            lock.withLock { installing = true }
            return .updating(phase: "Downloading", bytesToDownload: 1)
        }
        let downloading = lock.withLock {
            defer { downloadingChecks = max(downloadingChecks - 1, 0) }
            return downloadingChecks > 0
        }
        if downloading { return .updating(phase: "Downloading", bytesToDownload: 1_000_000) }
        if install == .installed, let queued, let game = GameInfoProvider.shared.allGames().first(where: { $0.steamAppID == queued.appID }) {
            let exe = prefix.appendingPathComponent(SteamClient.steamDirInPrefix)
                .appendingPathComponent("steamapps/common/\(queued.installDir)/\(game.steamExePath ?? "Game.exe")")
            try? FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: exe.path, contents: Data("MZ".utf8))
        }
        return install
    }
    func manifest(appID: Int) -> SteamAppManifest? { nil }
    func launch(appID: Int) throws { record("launch") }
    func shutdown(timeout: TimeInterval) async {
        record("shutdown")
        for file in SteamSessionStore.files {
            let url = prefix.appendingPathComponent(file)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("token".utf8))
        }
    }
}

/// Answers the game picker as a person would, offering what it was shown.
@MainActor
final class PickingInput: WrappBuildInput {
    let pick: String
    private(set) var offered: [String]?

    init(pick: String, environment: [String: String]) {
        self.pick = pick
        super.init(environment: environment, viewModel: nil)
    }

    override func chooseSteamGame(from owned: [GameInfo]) async throws -> GameInfo {
        offered = owned.map(\.id)
        return try #require(owned.first { $0.id == pick })
    }
}

/// Wine's network traffic: each read gives the next count, the last one
/// over and over; nil when there's none to give.
final class FakeNetworkCounter: WineNetworkCounting, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int64]?

    init(_ counts: [Int64]?) { self.counts = counts }

    func bytesReceived() async -> Int64? {
        lock.withLock {
            guard var counts, let first = counts.first else { return nil }
            if counts.count > 1 { counts.removeFirst() }
            self.counts = counts
            return first
        }
    }
}

struct FakePreparer: SteamWrappPreparing {
    func prepare(in folder: URL, runner configuration: RunnerConfiguration) async throws -> URL {
        let tree = folder.appendingPathComponent("steam-client.app")
        try SteamWrappBuilderTests.fakeWrapp(at: tree)
        return tree
    }
    func run(_ step: PlannedStep, in path: URL) async throws {}
    /// The module stages, the wine prefix and Steam's client, made as a
    /// small fake wrapp, with the ddraw.ini cnc-ddraw's steps edit.
    func makeStage(_ stage: PlannedStage, in tree: URL) async throws -> Bool {
        guard stage.isModuleStage else { return false }
        try SteamWrappBuilderTests.fakePrefix(at: tree)
        let ini = WrappLayout(app: tree).driveC.appendingPathComponent("windows/syswow64/ddraw.ini")
        try FileManager.default.createDirectory(at: ini.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[ddraw]\nmaintas=false\nwindowed=false\nhook=0\n".write(to: ini, atomically: true, encoding: .utf8)
        return true
    }
    /// Wine's steps run nothing.
    func wineExecutor(_ real: any ModuleExecutor) -> any ModuleExecutor { NoWine() }

    struct NoWine: ModuleExecutor {
        static let handles = ["DRIVES", "REGISTRY", "WINETRICKS", "MOUNT", "KEEP-DISCS", "HELPERS", "PREFIX"]
        func run(_ step: PlannedStep, in context: any StepContext) async throws {}
    }
}

@MainActor
@Suite("Steam wrapp build", .serialized)
struct SteamWrappBuilderTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("steam-build-\(UUID().uuidString)")

    /// The smallest wrapp the helper can configure and sign: a bundle with an
    /// executable, empty engine lists, and the prefix's `a:` drive.
    static func fakeWrapp(at path: URL) throws {
        let contents = path.appendingPathComponent("Contents")
        let fm = FileManager.default
        for dir in ["MacOS", "Resources", "SharedSupport/prefix/drive_c/users/crossover", "SharedSupport/prefix/dosdevices"] {
            try fm.createDirectory(at: contents.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let plist: [String: Any] = [
            "CFBundleIdentifier": "au.gare.callum.SecondChance.WrappTemplate",
            "CFBundleExecutable": "WrappTemplate",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try fm.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/WrappTemplate").path)
        try fm.createSymbolicLink(atPath: contents.appendingPathComponent("SharedSupport/prefix/dosdevices/a:").path,
                                  withDestinationPath: "/tmp")
    }

    /// What the module stages leave a tree with, faked: the prefix and its
    /// `a:` drive, and none of the template's files, which come last.
    static func fakePrefix(at path: URL) throws {
        let prefix = path.appendingPathComponent("Contents/SharedSupport/prefix")
        let fm = FileManager.default
        for dir in ["drive_c/users/crossover", "dosdevices"] {
            try fm.createDirectory(at: prefix.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let a = prefix.appendingPathComponent("dosdevices/a:")
        if (try? fm.destinationOfSymbolicLink(atPath: a.path)) == nil {
            try fm.createSymbolicLink(atPath: a.path, withDestinationPath: "/tmp")
        }
    }

    struct Run {
        let result: Result<URL, Error>
        let events: [WrappBuildEvent]
        let client: FakeSteamClient?
        /// Every client the build made (one for identifying the game, one per tree), in order.
        let clients: [FakeSteamClient]
        var calls: [String] { clients.flatMap(\.calls) }
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [WrappBuildEvent] = []
        func add(_ event: WrappBuildEvent) { lock.withLock { list.append(event) } }
        var all: [WrappBuildEvent] { lock.withLock { list } }
    }

    /// Build `game` headless, named up front as `STEAM_GAME_SLUG`; or, with
    /// `picking`, as the app does, choosing it once Steam has signed in.
    func build(game: String, mode: String? = nil, picking: PickingInput? = nil,
               network: [Int64]? = [0], stallNote: TimeInterval = 60, stallLimit: TimeInterval = 60,
               quietLimit: TimeInterval = 120,
               configure: @escaping (FakeSteamClient) -> Void = { _ in }) async -> Run {
        let bus = EventBus<AppEvent>()
        let events = Events()
        _ = await bus.subscribe { event in
            if case .wrappBuild(let build) = event { events.add(build) }
        }
        var environment = [
            "STEAM_GAME_SLUG": game,
            "OUTPUT_PATH": base.appendingPathComponent("out").path,
            "NON_INTERACTIVE": "true",
        ]
        environment["STEAM_LAUNCH_MODE"] = mode
        if picking != nil { environment = Self.appEnvironment(base: base) }
        var client: FakeSteamClient?
        var clients: [FakeSteamClient] = []
        let builder = SteamWrappBuilder(
            helper: WrappBuildHelper(bus: bus),
            installerRunner: GameInstallerRunner(catalog: GamePatchCatalog(manifestURL: base.appendingPathComponent("none.json")), bus: bus),
            sessionStore: SteamSessionStore(root: base.appendingPathComponent("store")),
            clientCache: SteamClientCache(directory: base.appendingPathComponent("client-cache")),
            lockFile: base.appendingPathComponent("store/active-wrapp.lock"),
            makeClient: { path in
                let fake = FakeSteamClient(wrappPath: path)
                fake.owned = Set(GameInfoProvider.shared.allGames().compactMap(\.steamAppID))
                configure(fake)
                client = fake
                clients.append(fake)
                return fake
            },
            preparer: FakePreparer(),
            signInPollInterval: .milliseconds(10),
            installPollInterval: .milliseconds(10),
            networkCounter: FakeNetworkCounter(network),
            downloadStallNote: stallNote,
            downloadStallLimit: stallLimit,
            steamExitedChecks: 3,
            signInQuietLimit: quietLimit,
            bus: bus
        )
        let result: Result<URL, Error>
        do {
            result = .success(try await builder.build(input: picking ?? WrappBuildInput(environment: environment, viewModel: nil)))
        } catch {
            result = .failure(error)
        }
        return Run(result: result, events: events.all, client: client, clients: clients)
    }

    /// A build from the app: nothing named, so the game is asked for.
    static func appEnvironment(base: URL) -> [String: String] {
        ["OUTPUT_PATH": base.appendingPathComponent("out").path]
    }

    func settings(_ wrapp: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: wrapp.appendingPathComponent("Contents/Resources/AppSettings.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("A game that must launch through Steam keeps Steam, and its sign-in doesn't ship")
    func viaSteam() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = await build(game: "thornton-hall")
        let wrapp = try run.result.get()
        let prefix = wrapp.appendingPathComponent("Contents/SharedSupport/prefix")

        let plist = try settings(wrapp)
        #expect(plist["GameEngine"] as? String == "wine-steam")
        #expect(plist["SteamGameId"] as? String == "226820")
        // Where the bundle installs it, a link to Steam's library.
        #expect(plist["GameExePath"] as? String == "/Program Files (x86)/Her Interactive/Ghost of Thornton Hall/Thornton.exe")
        let link = prefix.appendingPathComponent("drive_c/Program Files (x86)/Her Interactive/Ghost of Thornton Hall")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
                == "../Steam/steamapps/common/Nancy Drew The Ghost of Thornton Hall")
        #expect(plist["SteamLaunchMode"] == nil)
        let launch = try #require(try WrappSettings(of: WrappLayout(app: wrapp)).recordedLaunch)
        #expect(launch.program == "steam://rungameid/226820")
        #expect(launch.options["steam.exe"] == "wine:C:/Program Files (x86)/Her Interactive/Ghost of Thornton Hall/Thornton.exe")
        #expect(launch.fallback == nil)
        for file in SteamSessionStore.files {
            #expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent(file).path), "\(file) shipped in the wrapp")
        }
        #expect(run.client?.savedSignedIn == true)
        #expect(run.client?.calls.first == "restoreLogin")
        #expect(run.client?.calls.contains("queueInstall 226820") == true)

        let kinds = run.events.map { String(describing: $0).prefix { $0 != "(" } }
        for expected in ["started", "gameDetected", "engineRouted", "gameExeDetected", "wrappConfigured", "signed", "completed"] {
            #expect(kinds.contains(Substring(expected)), "no \(expected) event")
        }
    }

    @Test("A ScummVM game's data is copied out of Steam into the app, which keeps no Wine, and ScummVM runs it")
    func scummvm() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let wrapp = try await build(game: "haunted-mansion").result.get()
        let plist = try settings(wrapp)
        #expect(plist["GameEngine"] as? String == "scummvm")
        #expect(plist["SteamGameId"] == nil)
        #expect(plist["SteamLaunchMode"] == nil)  // no choice offered
        #expect(FileManager.default.fileExists(atPath: wrapp.appendingPathComponent("Contents/SharedSupport/game/Game.exe").path))
        #expect(!FileManager.default.fileExists(atPath: wrapp.appendingPathComponent("Contents/SharedSupport/prefix").path))
        let launch = try #require(try WrappSettings(of: WrappLayout(app: wrapp)).recordedLaunch)
        #expect(launch.program == "scummvm:/SharedSupport/game/")
    }

    @Test("A DRM-free game chosen to start directly is moved out of Steam, and Steam taken away")
    func direct() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let wrapp = try await build(game: "shadow-ranch", mode: "direct").result.get()
        let prefix = wrapp.appendingPathComponent("Contents/SharedSupport/prefix")
        let plist = try settings(wrapp)
        #expect(plist["GameEngine"] as? String == "wine")
        #expect(plist["SteamGameId"] == nil)
        let game = prefix.appendingPathComponent("drive_c/Nancy Drew/Secret of Shadow Ranch")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: game.path)) == nil)
        #expect(FileManager.default.fileExists(atPath: game.appendingPathComponent("Game.exe").path))
        #expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent(SteamClient.steamDirInPrefix).path))
        #expect(try WrappSettings(of: WrappLayout(app: wrapp)).recordedLaunch?.program == "wine:C:/Nancy Drew/Secret of Shadow Ranch/Game.exe")
    }

    @Test("Launching a DRM-free game via Steam keeps Steam running it")
    func directChoiceViaSteam() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let wrapp = try await build(game: "shadow-ranch", mode: "steam").result.get()
        let plist = try settings(wrapp)
        #expect(plist["GameEngine"] as? String == "wine-steam")
        #expect(plist["SteamLaunchMode"] as? String == "steam")
        let launch = try #require(try WrappSettings(of: WrappLayout(app: wrapp)).recordedLaunch)
        #expect(launch.fallback == "wine:C:/Nancy Drew/Secret of Shadow Ranch/Game.exe")
    }

    @Test("A game the account doesn't own fails, and Steam is shut down")
    func notOwned() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = await build(game: "thornton-hall") { $0.owned = [] }
        #expect(throws: WrappBuildError.steamGameNotOwned(title: "Ghost of Thornton Hall")) { try run.result.get() }
        #expect(run.client?.calls.contains("shutdown") == true)
        #expect(run.client?.savedSignedIn == true)  // the session itself was fine
        #expect(run.events.contains { if case .failed = $0 { return true }; return false })
    }

    @Test("From the app, the game is picked from those the account owns, and Steam restarts to install it")
    func pickAfterSignIn() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let picking = PickingInput(pick: "thornton-hall", environment: Self.appEnvironment(base: base))
        let thornton = 226820, shadowRanch = try #require(GameInfoProvider.shared.allGames().first { $0.id == "shadow-ranch" }?.steamAppID)
        let run = await build(game: "thornton-hall", picking: picking) { $0.owned = [thornton, shadowRanch, 999_999_999] }
        let wrapp = try run.result.get()

        // In the order the games came out, not by title.
        #expect(picking.offered == ["shadow-ranch", "thornton-hall"])
        #expect(try settings(wrapp)["SteamGameId"] as? String == "226820")
        // Nothing is queued until the game is known, and Steam installs it on
        // its next start: the build's own tree, given the sign-in again.
        #expect(run.calls == ["restoreLogin", "start", "shutdown", "saveLogin", "restoreLogin", "queueInstall 226820", "start", "shutdown", "saveLogin"])
        let prefix = wrapp.appendingPathComponent("Contents/SharedSupport/prefix")
        for file in SteamSessionStore.files {
            #expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent(file).path), "\(file) shipped in the wrapp")
        }
    }

    @Test("The client stage Steam signs in in has the stores its steps take")
    func clientPlanHasStores() async throws {
        let modules = try #require(Bundle.main.resourceURL).appendingPathComponent("Modules")
        let plan = try await SteamWrappPreparer.clientPlan(modules: modules)
        let named = plan.stages.flatMap(\.steps).flatMap { step in step.options.filter { $0.key.hasSuffix("-store") }.flatMap(\.value) }
        #expect(!named.isEmpty)
        for store in named { #expect(plan.stores.stores[store] != nil, "\(store) isn't in the plan") }
    }

    @Test("A game named up front is queued before Steam's first start, with no restart")
    func preselectedNoRestart() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = await build(game: "thornton-hall")
        _ = try run.result.get()
        #expect(run.client?.calls == ["restoreLogin", "queueInstall 226820", "start", "shutdown", "saveLogin"])
    }

    @Test("From the app, Steam's sign-in window is brought to the front when Steam asks for a sign-in, and the person told")
    func signInWindowComesForward() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let picking = PickingInput(pick: "thornton-hall", environment: Self.appEnvironment(base: base))
        let run = await build(game: "thornton-hall", picking: picking) {
            $0.owned = [226820]
            $0.login = .needsCredentials(reason: nil)
        }
        _ = try run.result.get()
        #expect(run.client?.calls.filter { $0 == "bringSignInWindowForward" }.count == 1)
        #expect(run.events.contains(where: Self.isSignInInstructions))
    }

    static func isSignInInstructions(_ event: WrappBuildEvent) -> Bool {
        if case .instructions(SteamWrappBuilder.signInInstructions) = event { return true }
        return false
    }

    @Test("From the app, nobody is told to sign in in Steam's window when Steam signs in by itself")
    func noSignInWindowNoInstructions() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let picking = PickingInput(pick: "thornton-hall", environment: Self.appEnvironment(base: base))
        let run = await build(game: "thornton-hall", picking: picking) { $0.owned = [226820] }
        _ = try run.result.get()
        #expect(!run.events.contains(where: Self.isSignInInstructions))
        #expect(run.client?.calls.contains("bringSignInWindowForward") == false)
    }

    @Test("An account that owns none of the games fails without asking which to build")
    func ownsNone() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let picking = PickingInput(pick: "thornton-hall", environment: Self.appEnvironment(base: base))
        let run = await build(game: "thornton-hall", picking: picking) { $0.owned = [999_999_999] }
        #expect(throws: WrappBuildError.steamNoGamesOwned) { try run.result.get() }
        #expect(picking.offered == nil)
        #expect(run.client?.calls.contains("shutdown") == true)
    }

    @Test("Headless with no game named fails before Steam is touched")
    func headlessNeedsGame() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let input = WrappBuildInput(environment: ["NON_INTERACTIVE": "true"], viewModel: nil)
        #expect(throws: WrappBuildError.missingRequiredParameter("STEAM_GAME_SLUG")) {
            try input.steamGameFromEnvironment(among: GameInfoProvider.shared.allGames())
        }
    }

    @Test("Headless with no saved sign-in fails before starting Steam")
    func headlessNeedsSession() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = await build(game: "thornton-hall") { $0.hasSession = false }
        #expect(throws: WrappBuildError.steamSignInRequired) { try run.result.get() }
        #expect(run.client?.calls.contains("start") == false)
    }

    @Test("A rejected sign-in, headless, fails and saves nothing")
    func rejected() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = await build(game: "thornton-hall") { $0.login = .needsCredentials(reason: "Invalid Password") }
        #expect(throws: WrappBuildError.steamSignInRequired) { try run.result.get() }
        #expect(run.client?.savedSignedIn == false)
    }

    @Test("Steam's install failing fails the build")
    func installFails() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = await build(game: "thornton-hall") { $0.install = .failed("Disk Write Failure") }
        #expect(throws: WrappBuildError.steamInstallFailed(reason: "Disk Write Failure")) { try run.result.get() }
    }

    @Test("Not enough disk space says so in everyday words")
    func diskFull() {
        let message = WrappBuildError.notEnoughSpace(needed: nil, available: nil).playerMessage
        #expect(message.contains("space"))
        #expect(message.contains("Free up some space"))
    }

    @Test("Steam exiting before it signs in is started again, and the build carries on")
    func exitedOnceRestarts() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = await build(game: "thornton-hall") { $0.exitsBeforeSignIn = 1 }
        _ = try run.result.get()
        #expect(run.client?.calls.filter { $0 == "start" }.count == 2)
    }

    @Test("While Steam updates itself before signing in, the progress line says so")
    func updatingBeforeSignIn() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = await build(game: "thornton-hall") { $0.updatingChecks = 3 }
        _ = try run.result.get()
        #expect(run.events.contains {
            if case .progress(.installingGame(substep: "Updating Steam", _)) = $0 { return true }
            return false
        })
        // With the download's figures, for the progress bar.
        #expect(run.events.contains {
            if case .stepProgress(StepProgress(fraction: 0.5, text: "50 of 100 MB")) = $0 { return true }
            return false
        })
    }

    @Test("Steam that goes quiet is warned about, started again once stuck, and stuck again fails a headless build")
    func quietSteamIsStuck() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = await build(game: "thornton-hall", quietLimit: 0.2) { $0.login = .pending }
        #expect(throws: WrappBuildError.steamStoppedResponding) { try run.result.get() }
        #expect(run.client?.calls.filter { $0 == "start" }.count == 2)
        #expect(run.events.contains {
            if case .steamSignInNotice(.slow(restartAt: .some)) = $0 { return true }
            return false
        })
    }

    @Test("Steam writing to its logs, as an update does, isn't stuck however long it takes")
    func busySteamIsNotStuck() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        // 60 checks 10 ms apart: three times the limit.
        let run = await build(game: "thornton-hall", quietLimit: 0.2) { $0.updatingChecks = 60 }
        _ = try run.result.get()
    }

    @Test("Steam exiting twice before it signs in fails the build")
    func exitedTwiceFails() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = await build(game: "thornton-hall") { $0.exitsBeforeSignIn = 2 }
        #expect(throws: WrappBuildError.steamExited) { try run.result.get() }
        #expect(run.client?.calls.filter { $0 == "start" }.count == 2)
    }

    @Test("Steam exiting partway through the install fails the build, rather than waiting out the timeout")
    func exitedWhileInstalling() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = await build(game: "thornton-hall") { $0.exitsWhileInstalling = true }
        #expect(throws: WrappBuildError.steamExitedWhileInstalling) { try run.result.get() }
        #expect(run.client?.calls.contains("shutdown") == true)
    }

    @Test("A download's figures fill the progress bar as it goes")
    func downloadProgress() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = await build(game: "thornton-hall", network: [5_000, 255_000, 505_000, 755_000]) { $0.downloadingChecks = 6 }
        _ = try run.result.get()
        let fractions = run.events.compactMap { event -> Double? in
            if case .stepProgress(let progress?) = event { return progress.fraction }
            return nil
        }
        // Counted from where the download started, not from Wine's start.
        #expect(fractions.first == 0)
        #expect(fractions.last == 0.75)
        #expect(fractions == fractions.sorted())
    }

    @Test("A download that gets nowhere is told to the person, then fails the build")
    func downloadStalls() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        // Both limits already passed at every check, as on a Mac too busy to
        // check in time: the person is still told before the build gives up.
        let run = await build(game: "thornton-hall", network: [5_000], stallNote: 0, stallLimit: 0) { $0.downloadingChecks = 10_000 }
        #expect(throws: WrappBuildError.steamDownloadStalled) { try run.result.get() }
        let told = run.events.firstIndex {
            if case .instructions(SteamWrappBuilder.downloadStalledInstructions) = $0 { return true }
            return false
        }
        let failed = run.events.firstIndex { if case .failed = $0 { return true }; return false }
        #expect(told != nil)
        #expect(told.flatMap { told in failed.map { told < $0 } } == true)
    }

    @Test("Without Wine's network counts, a download shows its phase alone")
    func noNetworkCounts() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = await build(game: "thornton-hall", network: nil) { $0.downloadingChecks = 3 }
        _ = try run.result.get()
        #expect(!run.events.contains { if case .stepProgress(.some) = $0 { return true }; return false })
    }

    @Test("Another wrapp using Steam stops the build before anything is made")
    func steamInUse() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        guard case .acquired(let held) = try SteamActiveLock.acquire(root: base.appendingPathComponent("store"), bundleID: "au.example.game") else {
            Issue.record("couldn't take the lock")
            return
        }
        defer { held.release() }
        let run = await build(game: "thornton-hall")
        #expect(throws: WrappBuildError.steamInUse(SteamLockHolder(pid: getpid(), bundleID: "au.example.game"))) { try run.result.get() }
        #expect(run.client == nil)
    }

    @Test("Progress names Steam's phase, never a made-up percentage")
    func substeps() {
        #expect(SteamWrappBuilder.substep(for: .updating(phase: "Downloading", bytesToDownload: 396_785_744)).hasPrefix("Downloading 396.8 MB"))
        #expect(SteamWrappBuilder.substep(for: .updating(phase: "Verifying Staged", bytesToDownload: nil)) == "Checking the download")
        #expect(SteamWrappBuilder.substep(for: .updating(phase: "Committing", bytesToDownload: 1)) == "Finishing the install")
        #expect(!SteamWrappBuilder.substep(for: .waiting).contains("%"))
    }
}
