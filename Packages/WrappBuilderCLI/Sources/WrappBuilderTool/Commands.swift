import ArgumentParser
import Foundation
import WrappBuilder

/// `wrapp-builder`: the builder's own tool, which builds, checks and
/// formats Wrappfiles knowing nothing of Second Chance's
/// (docs/dev-cli.md#wrapp-builder).
public struct WrappBuilderCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "wrapp-builder",
        abstract: "Check, plan and format Wrappfiles, and look after modules and engines.",
        subcommands: [CheckCommand.self, PlanCommand.self, BuildCommand.self, FormatCommand.self, ModuleCommand.self, EngineCommand.self]
    )

    public init() {}
}

/// Where the modules are: `--modules`, else `Modules/` in the current folder.
struct ModulesOption: ParsableArguments {
    @Option(help: ArgumentHelp("The modules folder (default: ./Modules).", valueName: "dir"))
    var modules: String?

    var root: URL {
        URL(fileURLWithPath: (modules ?? "Modules") as NSString as String, isDirectory: true).standardizedFileURL
    }

    /// `releases.json` beside the modules.
    var releases: URL { root.appendingPathComponent("releases.json") }
}

/// The downloader the tool's commands share: the builder's cache.
nonisolated extension Downloader {
    static func forTool() -> Downloader {
        Downloader(cache: Downloader.standardCache(), userAgent: "wrapp-builder (+https://github.com/callumgare/second-chance)")
    }
}

/// A `ToolError` as the tool's failure: its sentence, and a non-zero exit.
func runReporting(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let error as ToolError {
        StandardOutput().line("error: \(error.description)")
        throw ExitCode.failure
    }
}

struct CheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Parse and check a bundle's Wrappfile, planning every edition, without building it."
    )

    @OptionGroup var modules: ModulesOption

    @Argument(help: "The bundle's folder.")
    var bundle: String

    func run() async throws {
        try await runReporting {
            let output = StandardOutput()
            let loaded = try ModuleTool.loadAll(root: modules.root, output: output)
            try WrappfileTool.check(bundle: URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL,
                                    modules: loaded, output: output)
        }
    }
}

struct PlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Show what building a bundle's stage would run.",
        discussion: "Its stages, dependencies first, each step with its functions expanded, ${...} substituted and IFs decided for this Mac."
    )

    @OptionGroup var modules: ModulesOption

    @Argument(help: "The bundle's folder.")
    var bundle: String

    @Option(help: "The stage to build.")
    var target: String?

    @Option(help: "The edition whose inputs it's given (default: the first whose target it is).")
    var edition: String?

    @Option(name: .customLong("input"), help: ArgumentHelp("A value for an input, <name>=<value>; repeat it for more.", valueName: "name=value"))
    var inputs: [String] = []

    @Option(name: .customLong("allow-path"), help: ArgumentHelp(
        "A folder of the bundle's its Wrappfile may read (assets/), beside the manifest's allow-paths; * for any.", valueName: "folder"))
    var allowPaths: [String] = []

    func run() async throws {
        try await runReporting {
            let output = StandardOutput()
            var conditions = BuildConditions.thisMac
            for value in inputs {
                guard let equals = value.firstIndex(of: "="), equals != value.startIndex else {
                    throw ToolError("--input \(value) isn't <name>=<value>.")
                }
                conditions.choices[String(value[..<equals])] = String(value[value.index(after: equals)...])
            }
            try WrappfileTool.plan(bundle: URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL,
                                   modules: try ModuleTool.loadAll(root: modules.root, output: output),
                                   edition: edition, target: target, conditions: conditions, allowPaths: allowPaths, output: output)
            if allowPaths.contains("*") { output.line("warning: --allow-path=*: host paths aren't being checked") }
        }
    }
}

struct BuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build a bundle's stage into an app, with the executors this tool has.",
        discussion: """
        Inputs are given by name as paths (--input game=<folder>). Without --template \
        the result holds what the steps made and isn't an app that runs. A step \
        that asks something asks on the terminal, and fails without one.
        """
    )

    @OptionGroup var modules: ModulesOption

    @Argument(help: "The bundle's folder.")
    var bundle: String

    @Option(help: "The stage to build.")
    var target: String?

    @Option(help: "The edition whose inputs it's given (default: the first whose target it is).")
    var edition: String?

    @Option(name: .customLong("input"), help: ArgumentHelp("An input, <name>=<path>; repeat it for more.", valueName: "name=path"))
    var inputs: [String] = []

    @Option(help: "The app's id, over the Wrappfile's APP --default-id.")
    var appId: String?

    @Option(help: "The app whose files are laid in at the end (the launcher).")
    var template: String?

    @Option(help: ArgumentHelp("Where to put the app.", valueName: "app"))
    var out: String

    @Option(name: .customLong("allow-path"), help: ArgumentHelp("A folder of the bundle's its Wrappfile may read; * for any.", valueName: "folder"))
    var allowPaths: [String] = []

    @Option(help: "How events are printed: plain, or json (one object a line).")
    var events: String = "plain"

    func run() async throws {
        try await runReporting {
            var given: [String: URL] = [:]
            for value in inputs {
                guard let equals = value.firstIndex(of: "="), equals != value.startIndex else {
                    throw ToolError("--input \(value) isn't <name>=<path>.")
                }
                given[String(value[..<equals])] = URL(fileURLWithPath: String(value[value.index(after: equals)...])).standardizedFileURL
            }
            let output = StandardOutput()
            if allowPaths.contains("*") { output.line("warning: --allow-path=*: host paths aren't being checked") }
            try await BuildTool.build(.init(
                bundle: URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL, modules: modules.root,
                edition: edition, target: target, inputs: given, appID: appId,
                template: template.map { URL(fileURLWithPath: $0, isDirectory: true) },
                output: URL(fileURLWithPath: out, isDirectory: true).standardizedFileURL,
                allowPaths: allowPaths, json: events == "json"), output: output)
        }
    }
}

struct FormatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fmt",
        abstract: "Write Wrappfiles in the one style, in place.",
        discussion: "A folder is searched for Wrappfiles, and modules' stages and functions. docs/wrappfile.md#style has the style."
    )

    @Argument(help: "Wrappfiles, or folders holding them.")
    var paths: [String]

    @Flag(help: "Change nothing: say which files aren't formatted, and fail if any.")
    var check = false

    @Flag(help: "Rewrite syntax that has changed first (module:<id>:/<path>, FROM --module=, APP --icon, --keys-must-exist).")
    var migrate = false

    func run() async throws {
        try await runReporting {
            let files = try WrappfileTool.wrappfiles(in: paths.map { URL(fileURLWithPath: $0).standardizedFileURL })
            let unformatted = try WrappfileTool.format(files, check: check, migrate: migrate, output: StandardOutput())
            if check, !unformatted.isEmpty {
                throw ToolError("\(unformatted.count) of \(files.count) Wrappfiles aren't formatted.")
            }
        }
    }
}

struct ModuleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "module",
        abstract: "Check modules, and record their releases.",
        subcommands: [ModuleCheck.self, ModuleRelease.self]
    )

    struct ModuleCheck: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "check", abstract: "Check modules against the schema and their recorded releases.")
        @OptionGroup var modules: ModulesOption
        @Argument(help: "Module ids to check (default: every module).") var ids: [String] = []

        func run() async throws {
            try await runReporting {
                try ModuleTool.check(root: modules.root, releases: modules.releases, ids: ids, output: StandardOutput())
            }
        }
    }

    struct ModuleRelease: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "release", abstract: "Record a module's files as its release.")
        @OptionGroup var modules: ModulesOption
        @Argument(help: "The module's id.") var id: String

        func run() async throws {
            try await runReporting {
                try ModuleTool.release(root: modules.root, releases: modules.releases, id: id, output: StandardOutput())
            }
        }
    }
}

struct EngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "engine",
        abstract: "Prepare the engines modules' packages describe.",
        subcommands: [EnginePrepare.self, EngineFetch.self, EngineCheck.self]
    )

    struct EnginePrepare: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "prepare", abstract: "Prepare an engine version, and print the hash of its tree.")
        @OptionGroup var modules: ModulesOption
        @Argument(help: "The module's id (wine, scummvm).") var id: String
        @Option(help: "The version to prepare (default: the newest with a package).") var version: String?
        @Option(help: "Where to leave the prepared tree (default: a temporary folder, removed after).") var into: String?

        func run() async throws {
            try await runReporting {
                try await EngineTool.prepare(root: modules.root, id: id, version: version,
                                             into: into.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                             downloader: .forTool(), output: StandardOutput())
            }
        }
    }

    struct EngineFetch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "fetch", abstract: "Put engines in this Mac's engine store, as a build would.")
        @OptionGroup var modules: ModulesOption
        @Argument(help: "Module ids (default: every module with an engine package).") var ids: [String] = []
        @Option(help: "The version to fetch (default: the newest with a package).") var version: String?

        func run() async throws {
            try await runReporting {
                try await EngineTool.fetch(root: modules.root, ids: ids, version: version, downloader: .forTool(), output: StandardOutput())
            }
        }
    }

    struct EngineCheck: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "check", abstract: "Check every engine's downloads are still where their modules say.")
        @OptionGroup var modules: ModulesOption

        func run() async throws {
            try await runReporting { try await EngineTool.check(root: modules.root, output: StandardOutput()) }
        }
    }
}
