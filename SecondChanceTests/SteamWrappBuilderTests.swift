//
//  SteamWrappBuilderTests.swift
//  SecondChanceTests
//
//  The Steam build, end to end, with a fake Steam: what it publishes, what
//  ends up in the wrapp (and what must not), and how it fails.

import Foundation
import Testing
@testable import SecondChance

/// Steam as the builder sees it, without Wine. Its "install" puts the game's
/// exe where Steam would, and its shutdown leaves a sign-in behind in the
/// prefix, as a real Steam does, so the test can check it doesn't ship.
final class FakeSteamClient: SteamClientDriving, @unchecked Sendable {
    let prefix: URL
    var hasSession = true
    var login = SteamLogs.LoginState.signedIn
    var owned: Set<Int> = []
    var install = SteamLogs.InstallPhase.installed
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
    func start(silent: Bool) async throws { record("start") }
    func waitForLogin(timeout: TimeInterval) async -> SteamLogs.LoginState { login }
    /// The player signs in once the sign-in window is in front of them.
    func bringSignInWindowForward() async {
        record("bringSignInWindowForward")
        lock.withLock { login = .signedIn }
    }
    func ownedAppIDs(timeout: TimeInterval) async throws -> Set<Int> { owned }
    func installPhase(appID: Int) -> SteamLogs.InstallPhase {
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

struct FakePreparer: SteamWrappPreparing {
    func prepare(wrappAt path: URL) async throws { try SteamWrappBuilderTests.fakeWrapp(at: path) }
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
        fm.createFile(atPath: contents.appendingPathComponent("Resources/wine-files").path, contents: Data())
        fm.createFile(atPath: contents.appendingPathComponent("Resources/scummvm-files").path, contents: Data())
        try fm.createSymbolicLink(atPath: contents.appendingPathComponent("SharedSupport/prefix/dosdevices/a:").path,
                                  withDestinationPath: "/tmp")
    }

    struct Run {
        let result: Result<URL, Error>
        let events: [WrappBuildEvent]
        let client: FakeSteamClient?
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
        let builder = SteamWrappBuilder(
            helper: WrappBuildHelper(bus: bus),
            installerRunner: GameInstallerRunner(catalog: GamePatchCatalog(manifestURL: base.appendingPathComponent("none.json")), bus: bus),
            sessionStore: SteamSessionStore(root: base.appendingPathComponent("store")),
            clientCache: SteamClientCache(directory: base.appendingPathComponent("client-cache")),
            lockRoot: base.appendingPathComponent("store"),
            makeClient: { path in
                let fake = FakeSteamClient(wrappPath: path)
                fake.owned = Set(GameInfoProvider.shared.allGames().compactMap(\.steamAppID))
                configure(fake)
                client = fake
                return fake
            },
            preparer: FakePreparer(),
            bus: bus
        )
        let result: Result<URL, Error>
        do {
            result = .success(try await builder.build(input: picking ?? WrappBuildInput(environment: environment, viewModel: nil)))
        } catch {
            result = .failure(error)
        }
        return Run(result: result, events: events.all, client: client)
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
        #expect(plist["GameExePath"] as? String == "/Program Files (x86)/Steam/steamapps/common/Nancy Drew The Ghost of Thornton Hall/Thornton.exe")
        #expect(plist["SteamLaunchMode"] == nil)
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

    @Test("A ScummVM game is moved out of Steam, Steam is removed, and ScummVM runs it")
    func direct() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let wrapp = try await build(game: "haunted-mansion").result.get()
        let prefix = wrapp.appendingPathComponent("Contents/SharedSupport/prefix")
        let plist = try settings(wrapp)
        #expect(plist["GameEngine"] as? String == "scummvm")
        #expect(plist["GameExePath"] as? String == "/Program Files (x86)/Nancy Drew/Nancy Drew Message in a Haunted Mansion")
        #expect(plist["SteamGameId"] == nil)
        #expect(plist["SteamLaunchMode"] == nil)  // no choice offered
        #expect(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/Program Files (x86)/Nancy Drew/Nancy Drew Message in a Haunted Mansion/Game.exe").path))
        #expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent(SteamClient.steamDirInPrefix).path))
    }

    @Test("Launching a DRM-free game via Steam keeps Steam running it")
    func directChoiceViaSteam() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let plist = try settings(try await build(game: "shadow-ranch", mode: "steam").result.get())
        #expect(plist["GameEngine"] as? String == "wine-steam")
        #expect(plist["SteamLaunchMode"] as? String == "steam")
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
        // Nothing is queued until the game is known, and Steam installs it on its next start.
        #expect(run.client?.calls == ["restoreLogin", "start", "shutdown", "saveLogin", "queueInstall 226820", "start", "shutdown", "saveLogin"])
        let prefix = wrapp.appendingPathComponent("Contents/SharedSupport/prefix")
        for file in SteamSessionStore.files {
            #expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent(file).path), "\(file) shipped in the wrapp")
        }
    }

    @Test("A game named up front is queued before Steam's first start, with no restart")
    func preselectedNoRestart() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = await build(game: "thornton-hall")
        _ = try run.result.get()
        #expect(run.client?.calls == ["restoreLogin", "queueInstall 226820", "start", "shutdown", "saveLogin"])
    }

    @Test("From the app, Steam's sign-in window is brought to the front when Steam asks for a sign-in")
    func signInWindowComesForward() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let picking = PickingInput(pick: "thornton-hall", environment: Self.appEnvironment(base: base))
        let run = await build(game: "thornton-hall", picking: picking) {
            $0.owned = [226820]
            $0.login = .needsCredentials(reason: nil)
        }
        _ = try run.result.get()
        #expect(run.client?.calls.filter { $0 == "bringSignInWindowForward" }.count == 1)
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
