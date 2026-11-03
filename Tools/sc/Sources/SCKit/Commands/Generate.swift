import ArgumentParser
import Foundation
import WrappBuilder

struct GenerateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Write the Swift made from Bundles/ and Modules/.",
        discussion: """
        Code that reads no YAML — GameCatalog, and the wrapp — gets what it needs \
        of bundles and modules as Swift, generated and checked in: GameCatalog's \
        table of games, and the wrapp's routine Wine errors and Her engine log. Run this after \
        changing a bundle or a module's data; a test fails while a file is stale.
        """
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let session = try Session.start(global)
        let bundles: [ProgramBundle]
        switch try ProgramBundleLoader(root: session.repo.bundles, modules: try loadModules(session)).loadAll() {
        case .success(let loaded): bundles = loaded
        case .failure(let problems):
            for problem in problems.all { session.ui.line(problem.description) }
            throw SCError("Some bundles have problems; fix them first.")
        }
        let modules = try ModuleLoader(root: session.repo.modules)
        let files = [(GameCatalogSource.path, GameCatalogSource.source(for: GameCatalogSource.games(from: bundles)))]
            + (try ModuleDataSource.generatedFiles(modules: modules)).map { ($0.path, $0.source) }
        for (path, source) in files {
            let file = session.repo.root.appendingPathComponent(path)
            if (try? String(contentsOf: file, encoding: .utf8)) == source {
                session.ui.line("\(path) is up to date")
            } else {
                try source.write(to: file, atomically: true, encoding: .utf8)
                session.ui.line("Wrote \(path)")
            }
        }
        session.ui.success("Generated files are up to date.")
    }
}
