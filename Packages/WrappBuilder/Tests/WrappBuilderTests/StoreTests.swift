import Foundation
import Synchronization
import Testing
@testable import WrappBuilder
import WrappFormat
import WrappModules

/// Stores: what `STORE` and `LOCK` declare, how a mount names one, and the
/// runner's folders and locks.
struct StoreTests {
    private func declarations(_ text: String, module: String? = nil) throws -> StoreDeclarations {
        let file = try WrappfileParser.parse(text + "\nFROM scratch\n")
        return try StoreDeclarations.parse(file.storeDeclarations, module: module, origin: "Wrappfile")
    }

    @Test("A Wrappfile's stores are the app's, or global's, and a module's are its own")
    func owners() throws {
        let file = try declarations("STORE saves\nSTORE shared --scope=global --retention=cache")
        #expect(file.stores["app:saves"] == StoreDeclaration(owner: "app", name: "saves"))
        #expect(file.stores["global:shared"]?.retention == .cache)
        #expect(file.resolve("saves", module: nil) == "app:saves")
        #expect(file.resolve("global:shared", module: nil) == "global:shared")
        #expect(file.resolve("nothing", module: nil) == nil)

        let steam = try declarations("LOCK steam --scope=global\nSTORE sign-in --scope=global --exclusive=steam", module: "steam")
        #expect(steam.stores["steam:sign-in"]?.lock == "steam:steam")
        #expect(steam.resolve("sign-in", module: "steam") == "steam:sign-in")
    }

    @Test("--exclusive on its own is the store's own lock, with its scope")
    func ownLock() throws {
        let stores = try declarations("STORE saves --exclusive")
        #expect(stores.stores["app:saves"]?.lock == "app:saves")
        #expect(stores.locks["app:saves"]?.scope == .app)
    }

    @Test("What's wrong in a declaration is said", arguments: [
        ("STORE a --retention=session --scope=global", "can't be global"),
        ("STORE a --exclusive=nope", "there's no LOCK nope"),
        ("STORE a\nSTORE a", "declared already"),
        ("STORE A", "in lower case"),
        ("STORE a --size=1", "takes no --size"),
        ("LOCK a --retention=keep", "takes no --retention"),
    ])
    func problems(_ text: String, _ message: String) throws {
        #expect {
            _ = try declarations(text)
        } throws: { error in
            (error as? StoreDeclarations.Problem)?.description.contains(message) == true
        }
    }

    @Test("STORE comes before the first FROM, and VOLUME is gone")
    func whereStoresGo() {
        #expect(throws: WrappfileError.self) { try WrappfileParser.parse("FROM scratch\nSTORE a") }
        #expect(throws: WrappfileError.self) { try WrappfileParser.parse("FROM scratch\nVOLUME a C:/x") }
    }

    @Test("fmt --migrate makes each VOLUME a STORE and a LAUNCH that mounts it")
    func migratesVolumes() {
        let before = """
            INPUT game

            FROM scratch AS wine
            VOLUME --wine.drive=A: wine-documents C:/users/crossover/Documents
            VOLUME --dosbox.overlay dosbox-saves C:/
            LAUNCH C:/a.exe

            """
        let after = WrappfileFormatter.format(before, migrate: true)
        #expect(after == """
            INPUT game
            STORE wine-documents
            STORE dosbox-saves

            FROM scratch AS wine
            LAUNCH --mount=type=store,source=wine-documents,target=A: --mount=type=store,source=wine-documents,target=C:/users/crossover/Documents
            LAUNCH --mount=type=store,source=dosbox-saves,target=C:/,dosbox.overlay
            LAUNCH C:/a.exe

            """)
    }

    // MARK: - The runner

    private func run(_ steps: [PlannedStep], stores: StoreDeclarations, settings: StoreSettings, token: UUID = UUID(),
                     executor: (any ModuleExecutor)? = nil, recorder: PlanRunnerTests.Recorder = PlanRunnerTests.Recorder(),
                     in tree: URL) async throws {
        var plan = BuildPlan(edition: "x", stages: [PlannedStage(name: "only", from: .scratch, modules: ["fake"], steps: steps)])
        plan.stores = stores
        var configuration = RunnerConfiguration(executors: executor.map { ["fake": $0] } ?? [:], emitter: recorder,
                                                fetch: { _, _, _ in throw StepFailure.failed("no downloads") },
                                                pathTypes: PathTypeRegistry([]))
        configuration.stores = settings
        configuration.buildToken = token
        try await PlanRunner(plan: plan, configuration: configuration).run(in: tree)
    }

    private func settings(_ root: URL, wait: Duration = .seconds(30)) -> StoreSettings {
        StoreSettings(locations: StoreLocations(appSupport: root.appendingPathComponent("support"), caches: root.appendingPathComponent("caches"),
                                                session: root.appendingPathComponent("session")),
                      appID: "au.example.app", holder: "a test", lockWait: wait)
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stores-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tree.app/Contents"), withIntermediateDirectories: true)
        return root
    }

    @Test("A store mount is a link to the store while the step runs: what it writes is the store's, and the link goes after")
    func storeMount() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = try declarations("STORE downloads --retention=cache")
        let step = PlannedStep(instruction: "WRITE", module: "fake", options: ["mount": ["type=store,source=app:downloads,target=/cache"]],
                               arguments: [], name: nil, origin: "Wrappfile:3")
        let tree = root.appendingPathComponent("tree.app")
        try await run([step], stores: stores, settings: settings(root), executor: Writer(), in: tree)
        let folder = root.appendingPathComponent("caches/SecondChance/stores/au.example.app/app/downloads")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("kept.plist").path))
        #expect(!FileManager.default.fileExists(atPath: tree.appendingPathComponent("Contents/cache").path))
        // Its declaration, recorded beside it.
        #expect(FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("downloads.store.json").path))
    }

    @Test("A snapshot leaves what the store holds in the tree")
    func snapshot() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = try declarations("STORE client --retention=cache")
        let folder = root.appendingPathComponent("caches/SecondChance/stores/au.example.app/app/client")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("client".utf8).write(to: folder.appendingPathComponent("steam.exe"))
        let step = PlannedStep(instruction: "REMOVE", module: nil, options: ["mount": ["type=store,source=app:client,target=/client,snapshot"]],
                               arguments: ["/nothing"], name: nil, origin: "Wrappfile:3")
        let tree = root.appendingPathComponent("tree.app")
        try await run([step], stores: stores, settings: settings(root), in: tree)
        let kept = tree.appendingPathComponent("Contents/client")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: kept.path)) == nil)
        #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("steam.exe").path))
    }

    @Test("A build step can't mount a kept store")
    func keptStore() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = try declarations("STORE saves")
        let step = PlannedStep(instruction: "REMOVE", module: nil, options: ["mount": ["type=store,source=app:saves,target=/saves"]],
                               arguments: ["/nothing"], name: nil, origin: "Wrappfile:3")
        await #expect(throws: StepFailure.self) {
            try await run([step], stores: stores, settings: settings(root), in: root.appendingPathComponent("tree.app"))
        }
    }

    @Test("A store declared otherwise than it was made is refused, naming both")
    func declarationChanged() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = StoreDeclaration(owner: "app", name: "data", retention: .cache)
        _ = try StoreRuns.folder(of: first, settings: settings(root), origin: "W:1")
        let changed = StoreDeclaration(owner: "app", name: "data", retention: .cache, lock: "app:data")
        #expect {
            _ = try StoreRuns.folder(of: changed, settings: settings(root), origin: "W:2")
        } throws: { error in
            String(describing: error).contains("--exclusive=app:data") && String(describing: error).contains("was made")
        }
    }

    /// An executor that writes a file into the mount at `/cache`.
    struct Writer: ModuleExecutor {
        static let handles = ["WRITE"]
        func run(_ step: PlannedStep, in context: any StepContext) async throws {
            try Data("kept".utf8).write(to: context.tree.appendingPathComponent("Contents/cache/kept.plist"))
        }
    }

    /// An executor that takes a store and holds it until told to go on.
    final class Holder: ModuleExecutor {
        static let handles = ["HOLD"]
        let took = Mutex(false)
        let release = Mutex(false)
        func run(_ step: PlannedStep, in context: any StepContext) async throws {
            _ = try await context.store("fake:sign-in")
            took.withLock { $0 = true }
            while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
        }
    }

    @Test("A build waits for an exclusive store's lock while another holds it, and says so")
    func lockWaits() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = try declarations("LOCK one --scope=global\nSTORE sign-in --scope=global --exclusive=one", module: "fake")
        let step = PlannedStep(instruction: "HOLD", module: "fake", options: [:], arguments: [], name: nil, origin: "fake:1")
        let first = Holder(), second = Holder()
        let firstTree = root.appendingPathComponent("tree.app")
        let secondTree = root.appendingPathComponent("other.app")
        try FileManager.default.createDirectory(at: secondTree, withIntermediateDirectories: true)
        let settings = settings(root)
        let holding = Task { try await run([step], stores: stores, settings: settings, executor: first, in: firstTree) }
        let deadline = ContinuousClock.now + .seconds(10)
        while !first.took.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(first.took.withLock { $0 })

        let recorder = PlanRunnerTests.Recorder()
        let waiting = Task { try await run([step], stores: stores, settings: settings, executor: second, recorder: recorder, in: secondTree) }
        while !recorder.all.contains(where: { if case .lockWaiting = $0 { return true }; return false }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(recorder.all.contains { if case .lockWaiting(let lock, let holder) = $0 { return lock == "fake:one" && holder?.contains("a test") == true }; return false })
        #expect(!second.took.withLock { $0 })

        first.release.withLock { $0 = true }
        second.release.withLock { $0 = true }
        try await holding.value
        try await waiting.value
        #expect(recorder.all.contains { if case .lockAcquired(let lock, _) = $0 { return lock == "fake:one" }; return false })
    }

    @Test("The same build takes its own lock again without waiting")
    func sameBuildShares() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let mine = UUID()
        #expect(try ProcessLocks.tryTake(file, token: mine, holder: "one"))
        #expect(try ProcessLocks.tryTake(file, token: mine, holder: "one"))
        #expect(try !ProcessLocks.tryTake(file, token: UUID(), holder: "two"))
        ProcessLocks.release(file, token: mine)
        #expect(try !ProcessLocks.tryTake(file, token: UUID(), holder: "two"))
        ProcessLocks.release(file, token: mine)
        let other = UUID()
        #expect(try ProcessLocks.tryTake(file, token: other, holder: "two"))
        ProcessLocks.release(file, token: other)
    }
}
