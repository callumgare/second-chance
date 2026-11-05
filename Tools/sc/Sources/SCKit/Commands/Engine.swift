import ArgumentParser
import Foundation
import WrappBuilder
import WrappBuilderTool

struct EngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "engine",
        abstract: "Prepare the engines modules' packages describe.",
        discussion: "docs/modules.md#engine-packages describes an engine's package and its prepared hash.",
        subcommands: [EnginePrepareCommand.self, EngineFetchCommand.self, EngineCheckCommand.self]
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
        try await runTool {
            try await EngineTool.prepare(root: session.repo.modules, id: id, version: version,
                                         into: into.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                         downloader: Downloader.forSC(), output: session.toolOutput)
        }
    }
}

struct EngineFetchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Put engines in this Mac's engine store, as a build would.",
        discussion: """
        Prepares each engine module's newest version (or --version's) into \
        the engine store (~/Library/Caches/SecondChance/engines, or on a Mac \
        with test users the shared one) unless it is there already, so a \
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
        try await runTool {
            try await EngineTool.fetch(root: session.repo.modules, ids: ids, version: version, downloader: Downloader.forSC(),
                                       output: session.toolOutput)
        }
    }
}

struct EngineCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check every engine's downloads are still where their modules say.",
        discussion: "Asks each source's first URL for its headers, as sc release does before releasing."
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let session = try Session.start(global)
        try await runTool { try await EngineTool.check(root: session.repo.modules, output: session.toolOutput) }
    }
}

extension Downloader {
    /// The downloader sc's commands share: the app's cache, under sc's name.
    static func forSC() -> Downloader {
        Downloader(cache: Downloader.standardCache(), userAgent: "SecondChance-sc (+https://github.com/callumgare/second-chance)")
    }
}
