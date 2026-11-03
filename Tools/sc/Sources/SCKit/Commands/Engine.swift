import ArgumentParser
import Foundation
import WrappBuilder

struct EngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "engine",
        abstract: "Prepare the engines modules' packages describe.",
        discussion: "docs/modules.md#engine-packages describes an engine's package and its prepared hash.",
        subcommands: [EnginePrepareCommand.self, EngineFetchCommand.self]
    )
}

struct EnginePrepareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare",
        abstract: "Prepare an engine version from its downloads, and print the hash of its tree.",
        discussion: """
        Downloads the package's sources (once per Mac) and prepares them as a \
        build would. A package that names its `prepared` hash must give it; \
        one that doesn't yet is prepared, and its hash printed to add.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The module's id (wine, scummvm).")
    var id: String

    @Option(help: "The version to prepare (default: the newest with a package).")
    var version: String?

    @Option(help: "Where to leave the prepared tree (default: a temporary folder, removed after).")
    var into: String?

    func run() async throws {
        let session = try Session.start(global)
        let loader = try ModuleLoader(root: session.repo.modules)
        let module: ModuleFolder
        switch loader.load(session.repo.modules.appendingPathComponent(id)) {
        case .success(let loaded): module = loaded
        case .failure(let problems):
            for problem in problems.all { session.ui.line(problem.description) }
            throw SCError("\(id) has problems; fix them first.")
        }
        let kept = into.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let kept, FileManager.default.fileExists(atPath: kept.path) {
            throw SCError("\(kept.path) already exists.")
        }
        let tree = kept ?? FileManager.default.temporaryDirectory.appendingPathComponent("sc-engine-\(UUID().uuidString)")
        defer { if kept == nil { try? FileManager.default.removeItem(at: tree) } }

        let preparer = EnginePreparer(downloader: Downloader.forSC())
        let ui = session.ui
        let prepared = try await preparer.prepare(module, version: version, into: tree, checked: false) { step in
            ui.line(step)
        }
        let expected = module.manifest.package(version: prepared.version)?.package.prepared
        let files = try EngineTree.files(in: tree).count
        ui.line("\(id) \(prepared.version): \(files) files")
        ui.line("prepared: \"\(prepared.hash)\"")
        if let kept { ui.line("Left in \(kept.path)") }
        switch expected {
        case prepared.hash?:
            ui.success("It matches its package.")
        case let other?:
            throw SCError("Its package says \(other); this Mac prepared it differently.")
        case nil:
            ui.info("Its package names no prepared hash yet: add the line above to its version's package.")
        }
    }
}

struct EngineFetchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Put engines in this Mac's engine store, as a build would.",
        discussion: """
        Prepares each engine module's newest version (or --version's) into \
        ~/Library/Caches/SecondChance/engines unless it is there already, so a \
        build or test that follows needn't wait for it. With no ids, every \
        engine module.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Module ids (default: every module with an engine package).")
    var ids: [String] = []

    @Option(help: "The version to fetch (default: the newest with a package).")
    var version: String?

    func run() async throws {
        let session = try Session.start(global)
        let loader = try ModuleLoader(root: session.repo.modules)
        let modules = try loader.loadAll().get().filter { ids.isEmpty ? $0.manifest.package() != nil : ids.contains($0.manifest.id) }
        let missing = Set(ids).subtracting(modules.map(\.manifest.id))
        guard missing.isEmpty else { throw SCError("No module \(missing.sorted().joined(separator: ", ")).") }
        let store = EngineStore(root: EngineStore.standardRoot(), preparer: EnginePreparer(downloader: Downloader.forSC()))
        let ui = session.ui
        for module in modules {
            let engine = try await store.engine(module, version: version) { step in ui.line(step) }
            ui.line("\(engine.module) \(engine.version): \(engine.prepared ? "prepared" : "already here"), \(engine.tree.path)")
        }
        ui.success("\(modules.count) engine\(modules.count == 1 ? "" : "s") in the store.")
    }
}

extension Downloader {
    /// The downloader sc's commands share: the app's cache, under sc's name.
    static func forSC() -> Downloader {
        Downloader(cache: Downloader.standardCache(), userAgent: "SecondChance-sc (+https://github.com/callumgare/second-chance)")
    }
}
