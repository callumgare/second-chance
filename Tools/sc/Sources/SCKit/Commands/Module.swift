import ArgumentParser
import Foundation
import WrappBuilder

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
        let loader = try ModuleLoader(root: session.repo.modules)
        let releases = try ModuleReleases.read(from: session.repo.moduleReleases)
        let folders = ids.isEmpty ? try loader.moduleFolders() : ids.map { session.repo.modules.appendingPathComponent($0) }
        var failed = 0
        for folder in folders {
            switch loader.load(folder) {
            case .failure(let problems):
                failed += 1
                for problem in problems.all { session.ui.line(problem.description) }
            case .success(let module):
                let problems = try releases.problems(with: module)
                if !problems.isEmpty { failed += 1 }
                for problem in problems { session.ui.line("\(module.manifest.id): \(problem)") }
            }
        }
        guard failed == 0 else { throw SCError("\(failed) of \(folders.count) modules have problems.") }
        session.ui.success("\(folders.count) modules are valid, each at its recorded release.")
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
        let loader = try ModuleLoader(root: session.repo.modules)
        let module: ModuleFolder
        switch loader.load(session.repo.modules.appendingPathComponent(id)) {
        case .success(let loaded): module = loaded
        case .failure(let problems):
            for problem in problems.all { session.ui.line(problem.description) }
            throw SCError("\(id) has problems; fix them first.")
        }
        var releases = try ModuleReleases.read(from: session.repo.moduleReleases)
        let blocking = try releases.problems(with: module).filter { !$0.contains("isn't recorded") }
        guard blocking.isEmpty else {
            for problem in blocking { session.ui.line("\(id): \(problem)") }
            throw SCError("Release \(module.manifest.release) of \(id) can't be recorded.")
        }
        do {
            try releases.record(module)
        } catch let error as ModuleReleases.RecordError {
            throw SCError(error.description)
        }
        try releases.write(to: session.repo.moduleReleases)
        session.ui.success("Recorded release \(module.manifest.release) of \(id).")
    }
}
