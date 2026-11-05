import ArgumentParser
import Foundation
import WrappBuilder
import WrappBuilderTool

struct ModuleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "module",
        abstract: "Check the modules in Modules/, record their releases, and import one someone wrote.",
        discussion: "docs/modules.md describes a module, its releases and these commands; docs/module-programs.md, importing one.",
        subcommands: [ModuleCheckCommand.self, ModuleReleaseCommand.self, ModuleImportCommand.self]
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

struct ModuleImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import a module someone wrote, for this Mac's builds.",
        discussion: """
        Checks the module's module.yaml against the schema, that its id is \
        namespaced (<namespace>/<name>) and no shipped module's, and that its \
        program, if it has one, is built for arm64 and x86_64 and speaks a \
        module protocol this Second Chance does; then copies it into \
        ~/Library/Application Support/SecondChance/modules/, replacing one of \
        its id (docs/module-programs.md).
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The module's folder.")
    var folder: String

    func run() async throws {
        let session = try Session.start(global)
        try await runTool {
            try await ModuleTool.importModule(URL(fileURLWithPath: folder), shipped: session.repo.modules, output: session.toolOutput)
        }
    }
}
