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
        table of games, and the wrapp's routine Wine errors and Her engine log; and each \
        module's icons, compiled from Icon Composer's .icon to the .icns an app is given. \
        Run this after changing a bundle or a module's data; a test fails while a file is stale.
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
        let games = try GameCatalogSource.games(from: bundles, modules: try loadModules(session))
        let files = [(GameCatalogSource.path, GameCatalogSource.source(for: games))]
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
        try await compileIcons(session)
        session.ui.success("Generated files are up to date.")
    }

    /// Each module's Icon Composer icons (`assets/<name>.icon`) as the
    /// `.icns` a Wrappfile's `ICON` names (`assets/<name>.icns`): an app is
    /// built on Macs without Xcode, which alone compiles an `.icon`. actool's
    /// output is the same for the same icon, so an unchanged one is left be.
    func compileIcons(_ session: Session) async throws {
        let modules = session.repo.modules
        let files = FileManager.default
        for module in try files.contentsOfDirectory(atPath: modules.path).sorted() {
            let assets = modules.appendingPathComponent(module).appendingPathComponent("assets")
            for icon in ((try? files.contentsOfDirectory(atPath: assets.path)) ?? []).sorted() where icon.hasSuffix(".icon") {
                let name = String(icon.dropLast(".icon".count))
                let scratch = files.temporaryDirectory.appendingPathComponent("sc-icon-\(UUID().uuidString)")
                try files.createDirectory(at: scratch, withIntermediateDirectories: true)
                defer { try? files.removeItem(at: scratch) }
                let compiled = try await Proc.collect("/usr/bin/xcrun", [
                    "actool", assets.appendingPathComponent(icon).path, "--compile", scratch.path, "--app-icon", name,
                    "--platform", "macosx", "--minimum-deployment-target", "15.0",
                    "--output-partial-info-plist", scratch.appendingPathComponent("partial.plist").path,
                ])
                let made = scratch.appendingPathComponent("\(name).icns")
                guard compiled.status == 0, let data = try? Data(contentsOf: made) else {
                    throw SCError("actool couldn't compile Modules/\(module)/assets/\(icon).", hints: [compiled.error])
                }
                let path = "Modules/\(module)/assets/\(name).icns"
                let target = assets.appendingPathComponent("\(name).icns")
                if (try? Data(contentsOf: target)) == data {
                    session.ui.line("\(path) is up to date")
                } else {
                    try data.write(to: target)
                    session.ui.line("Wrote \(path)")
                }
            }
        }
    }
}
