import ArgumentParser
import Foundation
import WrappBuilder
import WrappBuilderTool

struct ModuleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "module",
        abstract: "Check the modules in Modules/, and record their releases.",
        discussion: "docs/modules.md describes a module, its releases and these commands.",
        subcommands: [ModuleCheckCommand.self, ModuleReleaseCommand.self]
    )
}

struct ModuleCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check modules against the schema and their recorded releases.",
        discussion: """
        A module whose files differ from what its release recorded has changed \
        without a new release; one whose release isn't recorded yet is compared \
        with the release before it, which it may not take anything away from \
        for a version it still provides. With no ids, checks every module.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Module ids to check (default: every module).")
    var ids: [String] = []

    func run() async throws {
        let session = try Session.start(global)
        try await runTool {
            try ModuleTool.check(root: session.repo.modules, releases: session.repo.moduleReleases, ids: ids, output: session.toolOutput)
        }
    }
}

struct ModuleReleaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Record a module's files as its release, in Modules/releases.json.",
        discussion: """
        Raise the module's `release:` first: a release, once recorded, never \
        changes. Checks the module, and that the release keeps what the one \
        before it provided, before recording it.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The module's id.")
    var id: String

    func run() async throws {
        let session = try Session.start(global)
        try await runTool {
            try ModuleTool.release(root: session.repo.modules, releases: session.repo.moduleReleases, id: id, output: session.toolOutput)
        }
    }
}
