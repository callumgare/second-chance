import Foundation
import WrappBuilder

/// Checking, planning and formatting Wrappfiles: `wrapp-builder check`,
/// `plan` and `fmt`, which `sc bundle` and `sc lint` use too.
public nonisolated enum WrappfileTool {
    /// Each Wrappfile formatted in place, or with `check`, only said to need
    /// it; `migrate` rewrites the syntax that has changed first. Returns the
    /// files that weren't (or aren't, with `check`) formatted.
    @discardableResult
    public static func format(_ files: [URL], check: Bool, migrate: Bool, output: some ToolOutput) throws -> [URL] {
        var unformatted: [URL] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let formatted = WrappfileFormatter.format(text, migrate: migrate)
            guard formatted != text else { continue }
            unformatted.append(file)
            if check {
                output.line("\(file.path): not formatted (wrapp-builder fmt\(migrate ? " --migrate" : "") rewrites it)")
            } else {
                try formatted.write(to: file, atomically: true, encoding: .utf8)
                output.line("Formatted \(file.path)")
            }
        }
        return unformatted
    }

    /// Every Wrappfile beneath `folders`: bundles' `Wrappfile`s, and each
    /// module's stages and functions.
    public static func wrappfiles(in folders: [URL]) throws -> [URL] {
        var found: [URL] = []
        for folder in folders {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) else { continue }
            guard isFolder.boolValue else {
                found.append(folder)
                continue
            }
            guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let file as URL in walk {
                let parent = file.deletingLastPathComponent().lastPathComponent
                if file.lastPathComponent == "Wrappfile" || ["stages", "functions"].contains(parent) && file.pathExtension.isEmpty {
                    found.append(file)
                }
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The bundle in `folder`, loaded and checked against `modules`: its
    /// manifest, and its Wrappfile with every edition planned.
    public static func check(bundle folder: URL, modules: [ModuleFolder], output: some ToolOutput) throws {
        let root = folder.deletingLastPathComponent().deletingLastPathComponent()
        let loader = try ProgramBundleLoader(root: root, modules: modules)
        for warning in loader.warnings(folder) { output.line("\(folder.path): warning: \(warning)") }
        switch loader.load(folder) {
        case .success:
            output.success("\(folder.lastPathComponent) is valid.")
        case .failure(let problems):
            for problem in problems.all { output.line(problem.description) }
            throw ToolError("\(folder.lastPathComponent) has problems.")
        }
    }

    /// The plan for building `target` (or `edition`'s target) of the bundle
    /// in `folder`, as lines: each stage, then its steps and where each was
    /// written.
    public static func plan(bundle folder: URL, modules: [ModuleFolder], edition: String?, target: String?,
                            conditions: BuildConditions, allowPaths: [String] = [], output: some ToolOutput) throws {
        let plan = try planned(bundle: folder, modules: modules, edition: edition, target: target, conditions: conditions,
                               allowPaths: allowPaths, output: output)
        for stage in plan.stages {
            output.result("FROM \(stage.from) AS \(stage.name)   [\(stage.modules.joined(separator: ", "))]")
            for step in stage.steps {
                output.result("  \(step)    # \(step.origin)")
            }
        }
    }

    /// The plan for building `target` (or `edition`'s target).
    static func planned(bundle folder: URL, modules: [ModuleFolder], edition: String?, target: String?,
                        conditions: BuildConditions, allowPaths: [String], output: some ToolOutput) throws -> BuildPlan {
        let root = folder.deletingLastPathComponent().deletingLastPathComponent()
        let loaded: ProgramBundle
        switch try ProgramBundleLoader(root: root, modules: modules).load(folder) {
        case .success(let found): loaded = found
        case .failure(let problems):
            for problem in problems.all { output.line(problem.description) }
            throw ToolError("\(folder.lastPathComponent) has problems.")
        }
        let wrappfile = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
        let planner = BuildPlanner(bundle: loaded, wrappfile: wrappfile, modules: modules,
                                   hostPaths: HostPaths(allowed: (loaded.manifest.allowPaths ?? []) + allowPaths))
        let editions = loaded.manifest.editions
        let chosen = edition ?? editions.first { target != nil && $0.build?.target?.lowercased() == target?.lowercased() }?.id
            ?? editions.first?.id
        guard let chosen else { throw ToolError("\(folder.lastPathComponent) has no editions.") }
        let plan: BuildPlan?
        do {
            if let target {
                plan = try planner.plan(edition: chosen, target: target, conditions: conditions)
            } else {
                plan = try planner.plan(edition: chosen, conditions: conditions)
            }
        } catch {
            throw ToolError(error.description)
        }
        guard let plan else { throw ToolError("\(chosen) names no stage.") }
        return plan
    }
}
