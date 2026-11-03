import ArgumentParser
import Foundation
import WrappBuilder

struct BundleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle",
        abstract: "Check, list and use the program bundles in Bundles/.",
        discussion: "docs/program-bundles.md describes a bundle and these commands.",
        subcommands: [BundleCheckCommand.self, BundleListCommand.self, BundlePlanCommand.self]
    )
}

struct BundlePlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Show what building one of a bundle's editions would run.",
        discussion: """
        The edition's stages, dependencies first, each step with its \
        functions expanded, ${...} substituted and IFs decided for this Mac, \
        and where each was written. docs/wrappfile.md has the syntax.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The bundle's id (nancy-drew/blue-moon) or a game's slug.")
    var bundle: String

    @Argument(help: "The edition's id (cd, her-windows, steam).")
    var edition: String

    func run() async throws {
        let session = try Session.start(global)
        let modules = try loadModules(session)
        let id = bundle.contains("/") ? bundle : "nancy-drew/\(bundle)"
        let folder = session.repo.bundles.appendingPathComponent(id)
        let loaded: ProgramBundle
        switch try ProgramBundleLoader(root: session.repo.bundles, modules: modules).load(folder) {
        case .success(let found): loaded = found
        case .failure(let problems):
            for problem in problems.all { session.ui.line(problem.description) }
            throw SCError("\(id) has problems.")
        }
        let wrappfile = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
        guard let plan = try BuildPlanner(bundle: loaded, wrappfile: wrappfile, modules: modules)
            .plan(edition: edition, conditions: .thisMac) else {
            session.ui.result("\(edition) names no stage: a module's default stages build it.")
            return
        }
        for stage in plan.stages {
            session.ui.result("FROM \(stage.from) AS \(stage.name)   [\(stage.modules.joined(separator: ", "))]")
            for step in stage.steps {
                session.ui.result("  \(step)    # \(step.origin)")
            }
        }
    }
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
        let loader = try ProgramBundleLoader(root: session.repo.bundles, modules: try loadModules(session))
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
        let loader = try ProgramBundleLoader(root: session.repo.bundles, modules: try loadModules(session))
        for folder in try loader.bundleFolders() {
            let document = try loader.document(in: folder)
            guard queries.allSatisfy({ $0.matches(document) }) else { continue }
            let id = (document as? [String: Any])?["id"] as? String
            session.ui.result(id ?? session.repo.display(folder))
        }
    }
}

/// Every module in Modules/, which bundles' Wrappfiles are checked against.
func loadModules(_ session: Session) throws -> [ModuleFolder] {
    switch try ModuleLoader(root: session.repo.modules).loadAll() {
    case .success(let modules): return modules
    case .failure(let problems):
        for problem in problems.all { session.ui.line(problem.description) }
        throw SCError("Some modules have problems; fix them first (sc module check).")
    }
}
