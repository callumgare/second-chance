//
//  BigFishWrappBuilderTests.swift
//  SecondChanceTests
//
//  The Big Fish build, end to end, with a fake Game Manager: what it
//  publishes, what ends up in the wrapp, and how it fails.

import Foundation
import Testing
@testable import SecondChance
@testable import SecondChanceKit
import GameCatalog

/// Big Fish's Game Manager as the builder sees it, without Wine. Its
/// download goes through `states` one look at a time (the last repeating),
/// and once one is ready (5) the game is in the prefix as Big Fish lays it out.
final class FakeGameManager: BigFishGameManaging, @unchecked Sendable {
    let prefix: URL
    var signedIn = true
    var owned: [BigFishOwnedGame] = []
    var states: [BigFishGameStatus] = [BigFishGameStatus(state: 5)]
    /// The person signs in once the sign-in window is in front of them.
    var signsInWhenShown = true
    /// It quits as soon as it's asked to download.
    var quitsOnDownload = false
    private var running = false
    private(set) var calls: [String] = []
    private(set) var downloaded: (sku: BigFishSKU, fullVersion: Bool)?
    private let lock = NSLock()

    init(wrappPath: URL) {
        prefix = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix")
    }

    var programFiles: URL { prefix.appendingPathComponent("drive_c/Program Files (x86)") }

    private func record(_ call: String) { lock.withLock { calls.append(call) } }

    var isInstalled: Bool { true }
    func start(timeout: TimeInterval) async throws {
        record("start")
        lock.withLock { running = true }
    }
    func isSignedIn() async throws -> Bool { lock.withLock { signedIn } }
    func showSignIn() async throws {
        record("showSignIn")
        if signsInWhenShown { lock.withLock { signedIn = true } }
    }
    func hideWindow() { record("hideWindow") }
    func signInForTesting(email: String, password: String) async throws {
        record("signInForTesting \(email)")
        lock.withLock { signedIn = true }
    }
    func ownedGames() async throws -> [BigFishOwnedGame] { owned }
    func download(_ sku: BigFishSKU, fullVersion: Bool) async throws {
        record("download \(sku) \(fullVersion ? "full" : "trial")")
        lock.withLock {
            downloaded = (sku, fullVersion)
            if quitsOnDownload { running = false }
        }
    }
    func status(of sku: BigFishSKU) async throws -> BigFishGameStatus? {
        let status = lock.withLock {
            defer { if states.count > 1 { states.removeFirst() } }
            return states.first
        }
        if status?.state == 5 { try install(sku) }
        return status
    }
    func installedGame(_ sku: BigFishSKU) -> BigFishInstalledGame? { BigFishInstalledGame.find(sku: sku, in: programFiles) }
    func isRunning() -> Bool { lock.withLock { running } }
    func signOut() async throws {
        record("signOut")
        lock.withLock { signedIn = false }
    }
    func play(_ sku: BigFishSKU) async throws { record("play \(sku)") }
    func shutdown(timeout: TimeInterval) async {
        record("shutdown")
        lock.withLock { running = false }
    }

    /// The game's folder as Big Fish's installer leaves it.
    private func install(_ sku: BigFishSKU) throws {
        guard let game = GameInfoProvider.shared.game(forBigFish: sku) else { return }
        let folder = programFiles.appendingPathComponent("Nancy Drew - \(game.title)")
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let state = """
        <bfgState><productID>\(sku)</productID>\
        <executablePath>C:\\Program Files (x86)\\Nancy Drew - \(game.title)\\rvlrkpp.exe</executablePath>\
        <trialLength>3600</trialLength></bfgState>
        """
        try Data(state.utf8).write(to: folder.appendingPathComponent("bfgstate.xml"))
        for file in ["Game.exe", "rvlrkpp.exe", "Uninstall.exe", "dxwebsetup.exe", "LaunchGame.bfg"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: Data("MZ".utf8))
        }
    }
}

/// Makes the smallest wrapp the helper can finish, with the Game Manager's
/// folder in it, and notes the DirectX canceller starting and stopping.
final class FakeBigFishPreparer: BigFishWrappPreparing, @unchecked Sendable {
    private(set) var directX: [String] = []

    func prepare(wrappAt path: URL) async throws {
        try SteamWrappBuilderTests.fakeWrapp(at: path)
        let client = path.appendingPathComponent("Contents/SharedSupport/prefix").appendingPathComponent(BigFishGameManager.clientDirInPrefix)
        try FileManager.default.createDirectory(at: client, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: client.appendingPathComponent("bfgclient.exe").path, contents: Data("MZ".utf8))
    }
    func startCancellingDirectXSetup(in path: URL) async { directX.append("start") }
    func stopCancellingDirectXSetup(in path: URL) async { directX.append("stop") }
    private(set) var forgotAccount = 0
    func forgetAccount(in path: URL) async throws { forgotAccount += 1 }
    private(set) var restoredSignIn = 0
    private(set) var keptSignIn = 0
    func restoreSignIn(into path: URL) async -> Bool {
        restoredSignIn += 1
        return true
    }
    func keepSignIn(from path: URL) async { keptSignIn += 1 }
}

/// Answers the game picker as a person would, offering what it was shown.
@MainActor
final class BigFishPickingInput: WrappBuildInput {
    let pick: String
    private(set) var offered: [String]?

    init(pick: String, environment: [String: String]) {
        self.pick = pick
        super.init(environment: environment, viewModel: nil)
    }

    override func chooseBigFishGame(from owned: [BigFishGameChoice]) async throws -> BigFishGameChoice {
        offered = owned.map(\.displayName)
        return try #require(owned.first { $0.sku.description == pick })
    }
}

@MainActor
@Suite("Big Fish wrapp build", .serialized)
struct BigFishWrappBuilderTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("big-fish-build-\(UUID().uuidString)")

    static let whiteWolf = "F2435T1L1"
    static let whiteWolfFrench = "F2435T1L4"
    static let hauntedMansion = "F5517T1L1"

    static func game(_ sku: String) throws -> GameInfo {
        let parsed = try #require(BigFishSKU(sku))
        return try #require(GameInfoProvider.shared.game(forBigFish: parsed))
    }

    struct Run {
        let result: Result<URL, Error>
        let events: [WrappBuildEvent]
        let manager: FakeGameManager?
        let preparer: FakeBigFishPreparer
    }

    /// Build headless, the game named up front; or, with `input`, as that input says.
    func build(game: String? = nil, environment extra: [String: String] = [:], input: WrappBuildInput? = nil,
               configure: @escaping (FakeGameManager) -> Void = { _ in }) async throws -> Run {
        let bus = EventBus<AppEvent>()
        let events = SteamWrappBuilderTests.Events()
        _ = await bus.subscribe { event in
            if case .wrappBuild(let build) = event { events.add(build) }
        }
        var environment = ["OUTPUT_PATH": base.appendingPathComponent("out").path, "NON_INTERACTIVE": "true"]
        if let game { environment["BIG_FISH_GAME_SLUG"] = try Self.game(game).id }
        environment.merge(extra) { _, new in new }
        var manager: FakeGameManager?
        let preparer = FakeBigFishPreparer()
        let builder = BigFishWrappBuilder(
            helper: WrappBuildHelper(bus: bus),
            installerRunner: GameInstallerRunner(catalog: GamePatchCatalog(manifestURL: base.appendingPathComponent("none.json")), bus: bus),
            makeManager: { path in
                let fake = FakeGameManager(wrappPath: path)
                fake.owned = [BigFishOwnedGame(sku: Self.whiteWolf, title: "White Wolf"),
                              BigFishOwnedGame(sku: Self.hauntedMansion, title: "Haunted Mansion")]
                configure(fake)
                manager = fake
                return fake
            },
            preparer: preparer,
            signInPollInterval: .milliseconds(10),
            installPollInterval: .milliseconds(10),
            signInTimeout: 1,
            bus: bus
        )
        let result: Result<URL, Error>
        do {
            result = .success(try await builder.build(input: input ?? WrappBuildInput(environment: environment, viewModel: nil)))
        } catch {
            result = .failure(error)
        }
        return Run(result: result, events: events.all, manager: manager, preparer: preparer)
    }

    var appEnvironment: [String: String] { ["OUTPUT_PATH": base.appendingPathComponent("out").path] }

    func settings(_ wrapp: URL) throws -> WrappSettings {
        try WrappSettings(of: WrappLayout(app: wrapp))
    }

    @Test("An owned game is downloaded, its launch file and edition recorded, and the person's sign-in kept but not shipped")
    func ownedGame() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try await build(game: Self.whiteWolf)
        let wrapp = try run.result.get()
        let title = try Self.game(Self.whiteWolf).title

        let settings = try settings(wrapp)
        #expect(settings.source == .bigFish)
        #expect(settings.engine == .wine)
        #expect(settings.gameExePath == "/Program Files (x86)/Nancy Drew - \(title)/Game.exe")
        #expect(settings.bigFishLaunchFile == "/Program Files (x86)/Nancy Drew - \(title)/LaunchGame.bfg")
        #expect(settings.bigFishSKU == Self.whiteWolf)
        #expect(settings.bigFishTrial == nil)
        // Started with the sign-in kept from before, kept again rather than
        // signed out, then taken out of the app.
        #expect(run.preparer.restoredSignIn == 1)
        #expect(run.manager?.calls == ["start", "download \(Self.whiteWolf) full", "shutdown"])
        #expect(run.preparer.keptSignIn == 1)
        #expect(run.preparer.directX == ["start", "stop"])
        #expect(run.preparer.forgotAccount == 1)
        // The Game Manager stays: its services start the game.
        let client = wrapp.appendingPathComponent("Contents/SharedSupport/prefix").appendingPathComponent(BigFishGameManager.clientDirInPrefix)
        #expect(FileManager.default.fileExists(atPath: client.path))

        let kinds = run.events.map { String(describing: $0).prefix { $0 != "(" } }
        for expected in ["started", "bigFishGamesOwned", "gameDetected", "engineRouted", "gameExeDetected", "wrappConfigured", "signed", "completed"] {
            #expect(kinds.contains(Substring(expected)), "no \(expected) event")
        }
    }

    @Test("A free trial downloads the English edition with no sign-in, library or sign-out, and says it's a trial")
    func trial() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try await build(game: Self.whiteWolf, environment: ["BIG_FISH_TRIAL": "1"]) {
            $0.signedIn = false
            $0.owned = []
        }
        let settings = try settings(try run.result.get())
        #expect(settings.bigFishTrial == true)
        #expect(settings.bigFishSKU == Self.whiteWolf)
        #expect(run.manager?.calls == ["start", "download \(Self.whiteWolf) trial", "shutdown"])
        #expect(run.preparer.restoredSignIn == 0 && run.preparer.keptSignIn == 0, "A trial touched the kept sign-in")
        #expect(!run.events.contains { if case .bigFishGamesOwned = $0 { return true }; return false })
    }

    @Test("From the app, the person picks from the editions they own, in the order the games came out")
    func pick() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let input = BigFishPickingInput(pick: Self.whiteWolfFrench, environment: appEnvironment)
        let run = try await build(input: input) {
            $0.owned = [BigFishOwnedGame(sku: Self.whiteWolfFrench, title: ""), BigFishOwnedGame(sku: Self.whiteWolf, title: ""),
                        BigFishOwnedGame(sku: Self.hauntedMansion, title: ""), BigFishOwnedGame(sku: "F999999T1L1", title: "Other"),
                        BigFishOwnedGame(sku: "not a sku", title: "")]
        }
        let wrapp = try run.result.get()
        let wolf = try Self.game(Self.whiteWolf).title, mansion = try Self.game(Self.hauntedMansion).title
        #expect(input.offered == [mansion, wolf, "\(wolf) (in French)"])
        #expect(try settings(wrapp).bigFishSKU == Self.whiteWolfFrench)
    }

    @Test("Named up front, the English edition is chosen over another the account also owns")
    func preselectedPrefersEnglish() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try await build(game: Self.whiteWolf) {
            $0.owned = [BigFishOwnedGame(sku: Self.whiteWolfFrench, title: ""), BigFishOwnedGame(sku: Self.whiteWolf, title: "")]
        }
        #expect(try settings(try run.result.get()).bigFishSKU == Self.whiteWolf)
    }

    @Test("A game named up front that the account doesn't own fails, and the Game Manager is shut down")
    func notOwned() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try await build(game: Self.whiteWolf) { $0.owned = [BigFishOwnedGame(sku: Self.hauntedMansion, title: "")] }
        #expect(throws: WrappBuildError.bigFishGameNotOwned(title: try Self.game(Self.whiteWolf).title)) { try run.result.get() }
        #expect(run.manager?.calls.last == "shutdown")
        #expect(run.events.contains { if case .failed = $0 { return true }; return false })
    }

    @Test("An account that owns none of the games fails without asking which to build")
    func ownsNone() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let input = BigFishPickingInput(pick: Self.whiteWolf, environment: appEnvironment)
        let run = try await build(input: input) { $0.owned = [BigFishOwnedGame(sku: "F999999T1L1", title: "Something else")] }
        #expect(throws: WrappBuildError.bigFishNoGamesOwned) { try run.result.get() }
        #expect(input.offered == nil)
    }

    @Test("Headless, with nobody to sign in, fails")
    func headlessNeedsSignIn() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try await build(game: Self.whiteWolf) { $0.signedIn = false }
        #expect(throws: WrappBuildError.bigFishSignInRequired) { try run.result.get() }
        #expect(run.manager?.calls.contains("showSignIn") == false)
        #expect(run.manager?.calls.last == "shutdown")
    }

    @Test("The test harness signs in with its own account")
    func testHarnessSignIn() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try await build(game: Self.whiteWolf, environment: [
            "BIG_FISH_TEST_SIGN_IN": "1", "BIG_FISH_EMAIL": "tester@example.com", "BIG_FISH_PASSWORD": "secret",
        ]) { $0.signedIn = false }
        _ = try run.result.get()
        #expect(run.manager?.calls.contains("signInForTesting tester@example.com") == true)
        // Its account is signed out, and neither uses nor replaces the person's kept sign-in.
        #expect(run.manager?.calls.contains("signOut") == true)
        #expect(run.preparer.restoredSignIn == 0)
        #expect(run.preparer.keptSignIn == 0)
    }

    @Test("From the app, the sign-in window comes forward and the person is told what to do")
    func personSignsIn() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let input = BigFishPickingInput(pick: Self.whiteWolf, environment: appEnvironment)
        let run = try await build(input: input) { $0.signedIn = false }
        _ = try run.result.get()
        let calls = run.manager?.calls ?? []
        let shown = try #require(calls.firstIndex(of: "showSignIn"))
        let hidden = try #require(calls.firstIndex(of: "hideWindow"), "The Game Manager's window was left on screen after the sign-in")
        #expect(shown < hidden)
        #expect(run.events.contains {
            if case .instructions(BigFishWrappBuilder.signInInstructions) = $0 { return true }
            return false
        })
    }

    @Test("Nobody signing in in time fails the build")
    func signInTimesOut() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let input = BigFishPickingInput(pick: Self.whiteWolf, environment: appEnvironment)
        let run = try await build(input: input) {
            $0.signedIn = false
            $0.signsInWhenShown = false
        }
        #expect(throws: WrappBuildError.bigFishSignInTimedOut) { try run.result.get() }
    }

    @Test("A failed download fails the build, and the half-made app is removed")
    func downloadFails() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try await build(game: Self.whiteWolf) {
            $0.states = [BigFishGameStatus(state: 1, downloadProgress: 10, downloadSize: 100), BigFishGameStatus(state: 7)]
        }
        #expect(throws: WrappBuildError.bigFishDownloadFailed) { try run.result.get() }
        #expect(run.manager?.calls.last == "shutdown")
        // So trying again needn't sign in again.
        #expect(run.preparer.keptSignIn == 1)
        #expect(run.preparer.directX.last == "stop")
        let working = run.events.compactMap { event -> URL? in
            if case .wrappStarted(let path) = event { return path }
            return nil
        }
        for path in working { #expect(!FileManager.default.fileExists(atPath: path.path)) }
    }

    @Test("A failed activation fails the build")
    func activationFails() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try await build(game: Self.whiteWolf) { $0.states = [BigFishGameStatus(state: 4), BigFishGameStatus(state: 8)] }
        #expect(throws: WrappBuildError.bigFishActivationFailed) { try run.result.get() }
    }

    @Test("The Game Manager quitting partway fails the build rather than waiting out the timeout")
    func managerQuits() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try await build(game: Self.whiteWolf) {
            $0.quitsOnDownload = true
            $0.states = [BigFishGameStatus(state: 1)]
        }
        #expect(throws: WrappBuildError.bigFishGameManagerQuit) { try run.result.get() }
    }

    @Test("Progress says downloading, installing, then activating, with the download's and install's figures")
    func progress() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try await build(game: Self.whiteWolf) {
            $0.states = [BigFishGameStatus(state: 0), BigFishGameStatus(state: 1, downloadProgress: 25, downloadSize: 100),
                         BigFishGameStatus(state: 1, downloadProgress: 50, downloadSize: 100), BigFishGameStatus(state: 4),
                         BigFishGameStatus(state: 4, installProgress: 40), BigFishGameStatus(state: 4, installProgress: 100),
                         BigFishGameStatus(state: 5)]
        }
        _ = try run.result.get()
        let substeps = run.events.compactMap { event -> String? in
            if case .progress(.installingGame(let substep?, _)) = event { return substep }
            return nil
        }
        let wanted = ["Waiting for the download to start", "Downloading the game", "Installing the game", "Activating the game"]
        #expect(substeps.filter(wanted.contains) == wanted)
        let fractions = run.events.compactMap { event -> Double? in
            if case .stepProgress(let progress?) = event { return progress.fraction }
            return nil
        }
        #expect(fractions == [0.25, 0.5, 0.4], "Activating has no percentage of its own")
    }

    @Test("A ScummVM game runs from its folder, without Big Fish's Game Manager")
    func scummVM() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try await build(game: Self.hauntedMansion)
        let wrapp = try run.result.get()
        let title = try Self.game(Self.hauntedMansion).title
        let settings = try settings(wrapp)
        #expect(settings.engine == .scummvm)
        #expect(settings.gameExePath == "/Program Files (x86)/Nancy Drew - \(title)")
        #expect(settings.bigFishLaunchFile == nil)
        let client = wrapp.appendingPathComponent("Contents/SharedSupport/prefix").appendingPathComponent(BigFishGameManager.clientDirInPrefix)
        #expect(!FileManager.default.fileExists(atPath: client.path))
        #expect(run.preparer.keptSignIn == 1)
    }

    @Test("Headless with no game named fails before anything is made")
    func headlessNeedsGame() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try await build()
        #expect(throws: WrappBuildError.missingRequiredParameter("BIG_FISH_GAME_SLUG")) { try run.result.get() }
        #expect(run.manager == nil)
    }

    @Test("Each edition's name says its language when it isn't English")
    func editionNames() throws {
        let wolf = try Self.game(Self.whiteWolf)
        let name = { (sku: String) in BigFishGameChoice(game: wolf, sku: try #require(BigFishSKU(sku))).displayName }
        #expect(try name("F2435T1L1") == wolf.title)
        #expect(try name("F2435T1L2") == "\(wolf.title) (in German)")
        #expect(try name("F2435T1L4") == "\(wolf.title) (in French)")
        #expect(try name("F2435T1L7") == "\(wolf.title) (in another language)")
    }

    @Test("Big Fish's installer is told from an error page by its size and its first bytes")
    func installerCheck() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bfg-\(UUID().uuidString).exe")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("MZ small".utf8).write(to: file)
        #expect(!BigFishWrappPreparer.isUsableInstaller(file))
        #expect(!BigFishWrappPreparer.isUsableInstaller(file.appendingPathExtension("missing")))
    }
}
