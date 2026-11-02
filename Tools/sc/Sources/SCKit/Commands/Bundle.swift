import ArgumentParser
import Foundation
import WrappBuilder

struct BundleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle",
        abstract: "Check, list and use the program bundles in Bundles/.",
        discussion: "docs/program-bundles.md describes a bundle and these commands.",
        subcommands: [BundleCheckCommand.self, BundleListCommand.self, BundleCatalogCommand.self]
    )
}

struct BundleCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check bundles against the manifest schema, without building them.",
        discussion: "With no paths, checks every bundle in Bundles/. A path is a bundle's folder."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Bundle folders to check (default: every bundle).")
    var paths: [String] = []

    func run() async throws {
        let session = try Session.start(global)
        let loader = try ProgramBundleLoader(root: session.repo.bundles)
        let folders = paths.isEmpty
            ? try loader.bundleFolders()
            : paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        var problems: [ProgramBundle.Problem] = []
        for folder in folders {
            if case .failure(let found) = loader.load(folder) { problems += found.all }
        }
        guard problems.isEmpty else {
            for problem in problems { session.ui.line(problem.description) }
            throw SCError("\(Set(problems.map(\.bundle)).count) of \(folders.count) bundles have problems.")
        }
        session.ui.success("\(folders.count) bundles are valid.")
    }
}

struct BundleListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List bundles' ids, optionally only those whose manifest has a value.",
        discussion: """
        --where takes a path into the manifest and a value: \
        --where notes.installer=installshield, --where series="Nancy Drew", \
        --where editions.source=steam (any edition). Repeat it to need every one.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Option(name: .customLong("where"), help: "<path>=<value> the manifest must have.")
    var conditions: [String] = []

    func run() async throws {
        let session = try Session.start(global)
        let queries = try conditions.map { text in
            guard let query = ManifestQuery(text) else {
                throw SCError("--where \(text) isn't <path>=<value>.", hints: ["For example: --where notes.installer=installshield"])
            }
            return query
        }
        let loader = try ProgramBundleLoader(root: session.repo.bundles)
        for folder in try loader.bundleFolders() {
            let document = try loader.document(in: folder)
            guard queries.allSatisfy({ $0.matches(document) }) else { continue }
            let id = (document as? [String: Any])?["id"] as? String
            session.ui.result(id ?? session.repo.display(folder))
        }
    }
}

struct BundleCatalogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catalog",
        abstract: "Write GameCatalog's table of games from the bundles.",
        discussion: """
        GameCatalog stays Foundation-only, so its table is generated from the \
        bundles and checked in rather than read at run time. Run this after \
        changing a bundle; a test fails while the file is stale.
        """
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let session = try Session.start(global)
        let loader = try ProgramBundleLoader(root: session.repo.bundles)
        let bundles: [ProgramBundle]
        switch try loader.loadAll() {
        case .success(let loaded): bundles = loaded
        case .failure(let problems):
            for problem in problems.all { session.ui.line(problem.description) }
            throw SCError("Some bundles have problems; fix them first.")
        }
        let file = session.repo.root.appendingPathComponent(GameCatalogSource.path)
        let source = GameCatalogSource.source(for: GameCatalogSource.games(from: bundles))
        if (try? String(contentsOf: file, encoding: .utf8)) == source {
            session.ui.success("\(session.repo.display(file)) is already up to date.")
            return
        }
        try source.write(to: file, atomically: true, encoding: .utf8)
        session.ui.success("Wrote \(session.repo.display(file)) from \(bundles.count) bundles.")
    }
}
