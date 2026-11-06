import Foundation
import GameCatalog
import WrappBuilder

/// `--bundle`: program bundles from beyond `Bundles/`, such as a port's
/// draft in `.local/porting/` (docs/program-bundles.md#extra-bundles).
enum ExtraBundleOptions {
    /// Checks each folder `given` names and makes its game known to this
    /// run: in sc's catalogue, and, through `SECOND_CHANCE_EXTRA_BUNDLES`
    /// in sc's environment, to every program sc starts (the app, a wrapp,
    /// the test host and WrappPuppeteer), and to a re-run in the GUI
    /// session. Unlike the app, which leaves out a bundle that doesn't
    /// load, sc stops on it: whoever named it wants to know.
    static func use(_ given: [String], repo: Repo) throws {
        guard !given.isEmpty else { return }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let named = try given.map { try resolve($0, cwd: cwd, shipped: repo.bundles) }
        ids = named.map { value in
            switch value {
            case .shipped(let id): id
            case .folder(let folder): ExtraBundles.id(of: folder) ?? folder.path
            }
        }
        let folders = named.compactMap { if case .folder(let folder) = $0 { folder } else { nil } }
        guard !folders.isEmpty else { return }
        let modules = try ModuleLoader(root: repo.modules).loadAll().get()
        let loader = try ProgramBundleLoader(root: repo.bundles, modules: modules)
        let bundles = try folders.map { folder -> ProgramBundle in
            switch loader.load(folder, anyFolder: true) {
            case .success(let bundle): return bundle
            case .failure(let problems):
                throw SCError("The bundle in \(repo.display(folder)) has problems.", hints: problems.all.map(\.message))
            }
        }
        var seen: Set<String> = []
        for bundle in bundles where !seen.insert(bundle.manifest.id).inserted {
            throw SCError("Two --bundle folders are \(bundle.manifest.id).")
        }
        setenv(ExtraBundles.environmentVariable, folders.map(\.path).joined(separator: ":"), 1)
        GameInfoProvider.shared.add(try GameCatalogSource.games(from: bundles, modules: modules))
    }

    /// What a `--bundle` names.
    enum Named: Equatable {
        /// A shipped bundle, by its id: the program, and no bundle beyond Bundles/.
        case shipped(String)
        /// A bundle's own folder, anywhere.
        case folder(URL)
    }

    /// What `value` names: a folder holding a `manifest.yaml` (from `cwd`
    /// unless absolute), else the id of a bundle in `shipped`.
    static func resolve(_ value: String, cwd: URL, shipped: URL) throws -> Named {
        let expanded = (value as NSString).expandingTildeInPath
        let folder = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded, isDirectory: true)
            : cwd.appendingPathComponent(expanded, isDirectory: true)).standardizedFileURL
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.yaml").path) { return .folder(folder) }
        if value.contains("/"), FileManager.default.fileExists(atPath: shipped.appendingPathComponent(value).appendingPathComponent("manifest.yaml").path) {
            return .shipped(value)
        }
        throw SCError("--bundle \(value) is neither a bundle's folder nor a bundle's id.",
                      hints: ["Name the bundle's own folder, the one with its manifest.yaml, or a shipped bundle's id (freeware/skifree)."])
    }

    /// The ids of the bundles `--bundle` named, in order: set by `use`.
    nonisolated(unsafe) static var ids: [String] = []
}
