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

    @Argument(help: "The bundle's id, e.g. nancy-drew/blue-moon or freeware/skifree.")
    var bundle: String

    @Argument(help: "The edition's id (cd, her-windows, steam).")
    var edition: String

    @OptionGroup var inputs: InputOptions

    func run() async throws {
        let session = try Session.start(global)
        let modules = try loadModules(session)
        guard bundle.contains("/") else {
            throw SCError("\(bundle) isn't a bundle's id: name it in full, as <namespace>/<name> (nancy-drew/blue-moon).")
        }
        let id = bundle
        // `--bundle`'s, when it named one with this id.
        let folder = ExtraBundles.folder(of: id, shippedRoot: session.repo.bundles)
        let loaded: ProgramBundle
        switch try ProgramBundleLoader(root: session.repo.bundles, modules: modules).load(folder, anyFolder: true) {
        case .success(let found): loaded = found
        case .failure(let problems):
            for problem in problems.all { session.ui.line(problem.description) }
            throw SCError("\(id) has problems.")
        }
        let wrappfile = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
        guard let plan = try BuildPlanner(bundle: loaded, wrappfile: wrappfile, modules: modules)
            .plan(edition: edition, conditions: conditions()) else {
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

extension BundlePlanCommand {
    /// This Mac, with the inputs given.
    func conditions() throws -> BuildConditions {
        var conditions = BuildConditions.thisMac
        conditions.choices = try inputs.parsed()
        return conditions
    }
}

struct BundleCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check bundles against the manifest schema and plan every edition, without building them.",
        discussion: """
        With no paths, checks every bundle in Bundles/, or only those --bundle names. A path is a bundle's folder; \
        one outside Bundles/ can be named anything.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Bundle folders to check (default: every bundle).")
    var paths: [String] = []

    func run() async throws {
        let session = try Session.start(global)
        let loader = try ProgramBundleLoader(root: session.repo.bundles, modules: try loadModules(session))
        let extras = ExtraBundles.folders()
        let folders = !paths.isEmpty ? paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            : !extras.isEmpty ? extras
            : try loader.bundleFolders()
        // Only a shipped bundle's folder must be <namespace>/<name>, as its id says.
        let shipped = session.repo.bundles.standardizedFileURL.path + "/"
        func load(_ folder: URL) -> Result<ProgramBundle, ProgramBundleLoader.Problems> {
            loader.load(folder, anyFolder: !folder.path.hasPrefix(shipped))
        }
        var problems: [ProgramBundle.Problem] = []
        for folder in folders {
            if case .failure(let found) = load(folder) { problems += found.all }
            for warning in loader.warnings(folder) {
                session.ui.line("\(session.repo.display(folder)): warning: \(warning)")
            }
        }
        // Second Chance's EMIT strings, which the builder never reads.
        let vocabulary = try EmitVocabulary.load(session.repo.root.appendingPathComponent(EmitVocabularySource.vocabularyPath))
        let modules = try loadModules(session)
        for folder in folders {
            guard case .success(let bundle) = load(folder),
                  let text = try? String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8),
                  let wrappfile = try? WrappfileParser.parse(text) else { continue }
            let planner = BuildPlanner(bundle: bundle, wrappfile: wrappfile, modules: modules)
            for edition in bundle.manifest.editions {
                guard let plan = try? planner.plan(edition: edition.id, conditions: .thisMac) else { continue }
                problems += vocabulary.problems(in: plan).map { ProgramBundle.Problem(bundle: bundle.manifest.id, message: $0) }
            }
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
