import Foundation
import WrappBuilder

/// Checking modules and recording their releases
/// (docs/modules.md#releases): `wrapp-builder module`, and `sc module`.
public nonisolated enum ModuleTool {
    /// Each module against the schema and its recorded release, and what's
    /// wrong across them. With no ids, every module in `root`.
    public static func check(root: URL, releases file: URL, ids: [String], output: some ToolOutput) throws {
        let loader = try ModuleLoader(root: root)
        let releases = try ModuleReleases.read(from: file)
        let folders = ids.isEmpty ? try loader.moduleFolders() : ids.map { root.appendingPathComponent($0) }
        var failed = 0
        for folder in folders {
            switch loader.load(folder) {
            case .failure(let problems):
                failed += 1
                for problem in problems.all { output.line(problem.description) }
            case .success(let module):
                let problems = try releases.problems(with: module)
                if !problems.isEmpty { failed += 1 }
                for problem in problems { output.line("\(module.manifest.id): \(problem)") }
            }
        }
        let loaded = folders.compactMap { try? loader.load($0).get() }
        let across = BuildModules.problems(across: loaded)
        for problem in across { output.line(problem) }
        guard failed == 0, across.isEmpty else {
            throw ToolError("\(failed) of \(folders.count) modules have problems\(across.isEmpty ? "" : ", and \(across.count) across them").")
        }
        output.success("\(folders.count) modules are valid, each at its recorded release.")
    }

    /// Record the module's files as its current release.
    public static func release(root: URL, releases file: URL, id: String, output: some ToolOutput) throws {
        let module = try load(id, root: root, output: output)
        var releases = try ModuleReleases.read(from: file)
        let blocking = try releases.problems(with: module).filter { !$0.contains("isn't recorded") }
        guard blocking.isEmpty else {
            for problem in blocking { output.line("\(id): \(problem)") }
            throw ToolError("Release \(module.manifest.release) of \(id) can't be recorded.")
        }
        do {
            try releases.record(module)
        } catch let error as ModuleReleases.RecordError {
            throw ToolError(error.description)
        }
        try releases.write(to: file)
        output.success("Recorded release \(module.manifest.release) of \(id).")
    }

    /// The module `id` in `root`, or its problems said and refused.
    public static func load(_ id: String, root: URL, output: some ToolOutput) throws -> ModuleFolder {
        switch try ModuleLoader(root: root).load(root.appendingPathComponent(id)) {
        case .success(let loaded): return loaded
        case .failure(let problems):
            for problem in problems.all { output.line(problem.description) }
            throw ToolError("\(id) has problems; fix them first.")
        }
    }

    /// Every module in `root`, or their problems said and refused.
    public static func loadAll(root: URL, output: some ToolOutput) throws -> [ModuleFolder] {
        switch try ModuleLoader(root: root).loadAll() {
        case .success(let modules): return modules
        case .failure(let problems):
            for problem in problems.all { output.line(problem.description) }
            throw ToolError("Some modules have problems; fix them first (module check).")
        }
    }
}
