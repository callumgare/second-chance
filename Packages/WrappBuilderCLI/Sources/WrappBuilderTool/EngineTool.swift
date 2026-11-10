import Foundation
import WrappBuilder

/// Preparing the engines modules' packages describe
/// (docs/modules.md#engine-packages): `wrapp-builder engine`, and `sc engine`.
public nonisolated enum EngineTool {
    /// Prepare `id`'s engine from its downloads, and say the hash of its tree.
    public static func prepare(root: URL, id: String, version: String?, into: URL?, downloader: Downloader,
                               output: some ToolOutput) async throws {
        let module = try ModuleTool.load(id, root: root, output: output)
        if let into, FileManager.default.fileExists(atPath: into.path) {
            throw ToolError("\(into.path) already exists.")
        }
        let tree = into ?? FileManager.default.temporaryDirectory.appendingPathComponent("wrapp-builder-engine-\(UUID().uuidString)")
        defer { if into == nil { try? FileManager.default.removeItem(at: tree) } }
        let prepared = try await EnginePreparer(downloader: downloader).prepare(module, version: version, into: tree, checked: false) { step in
            output.line(step)
        }
        let expected = module.manifest.package(version: prepared.version)?.package.prepared
        let files = try EngineTree.files(in: tree).count
        output.line("\(id) \(prepared.version): \(files) files")
        output.line("prepared: \"\(prepared.hash)\"")
        if let into { output.line("Left in \(into.path)") }
        switch expected {
        case prepared.hash?:
            output.success("It matches its package.")
        case let other?:
            throw ToolError("Its package says \(other); this Mac prepared it differently.")
        case nil:
            output.info("Its package names no prepared hash yet: add the line above to its version's package.")
        }
    }

    /// Put each engine module's newest version (or `version`) in the
    /// engine store, as a build would. With no ids, every engine module.
    public static func fetch(root: URL, ids: [String], version: String?, downloader: Downloader, output: some ToolOutput) async throws {
        let modules = try ModuleLoader(root: root).loadAll().get()
            .filter { ids.isEmpty ? $0.manifest.package() != nil : ids.contains($0.manifest.id) }
        let missing = Set(ids).subtracting(modules.map(\.manifest.id))
        guard missing.isEmpty else { throw ToolError("No module \(missing.sorted().joined(separator: ", ")).") }
        let store = EngineStore(root: EngineStore.standardRoot(), preparer: EnginePreparer(downloader: downloader))
        for module in modules {
            let engine = try await store.engine(module, version: version) { step in output.line(step) }
            output.line("\(engine.module) \(engine.version): \(engine.prepared ? "prepared" : "already here"), \(engine.tree.path)")
        }
        output.success("\(modules.count) engine\(modules.count == 1 ? "" : "s") in the store.")
    }

    /// Whether every engine's downloads are still where their modules say.
    public static func check(root: URL, output: some ToolOutput) async throws {
        let problems = try await EngineSources.check(modules: root)
        for problem in problems { output.line(problem.description) }
        for advice in EngineSources.advice(problems) { output.line(advice) }
        guard problems.isEmpty else {
            let summary = EngineSources.summary(problems)
            throw ToolError(summary.prefix(1).uppercased() + summary.dropFirst())
        }
        output.success("Every engine's downloads are where their modules say.")
    }
}
