//
//  ScummVMExecutor.swift
//  ScummVMExecutor
//
//  The scummvm module's executor: a game's app keeps only the engine data
//  its game needs.

import Foundation
import Logging
import ProcessKit
import WrappModuleKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.ScummVMExecutor")

/// Carries out `SCUMMVM.KEEP-DATA <file>…`: ScummVM's engine is installed
/// with every data file its app has (each engine's `.dat`, and what several
/// share: `classicmacfonts.dat`, `macgui.dat`, `fonts.dat`), about 80 MB a
/// game needs one or two of. This takes out the rest, leaving the files
/// named and what ScummVM's own windows always need (`alwaysKept`). Only
/// the engine's own files are touched: those its list
/// (`Resources/engines/scummvm.files`) names directly in `Resources/`, so
/// a bundle's own files there, its icon, stay. The list is written again
/// without them, so it still says what the engine is.
public nonisolated struct ScummVMExecutor: ModuleExecutor {
    public static let handles = ["KEEP-DATA"]

    /// What ScummVM's own windows (its warnings, its error console) need,
    /// and its licences, which go with every copy.
    static let alwaysKept: Set = ["shaders.dat", "shaders", "translations.dat", "gui-icons.dat",
                                  "COPYRIGHT", "COPYRIGHT.Roland_SC-55", "licenses"]

    /// The engine's list of its files, in a tree laid out as a wrapp
    /// (`EngineTree.listPath(module: "scummvm")`).
    static let listPath = "Contents/Resources/engines/scummvm.files"

    public init() {}

    public func run(_ step: PlannedStep, in context: any StepContext) async throws {
        guard step.instruction == "KEEP-DATA" else {
            throw StepFailure.recipe("\(step.origin): the scummvm module has no instruction \(step.instruction)")
        }
        guard !step.arguments.isEmpty else {
            throw StepFailure.recipe("\(step.origin): SCUMMVM.KEEP-DATA names the data files to keep (nancy.dat)")
        }
        let tree = context.tree
        let kept = Set(step.arguments)
        let removed = try await Blocking.run { try Self.keep(kept, in: tree) }
        logger.notice("Kept ScummVM's \(step.arguments.joined(separator: ", ")); took out \(removed.count) other data files")
    }

    /// Takes out of `tree` the engine's data files not in `kept` or
    /// `alwaysKept`, and returns their names. A name `kept` gives that the
    /// engine doesn't have fails, as it would be a game that can't start.
    static func keep(_ kept: Set<String>, in tree: URL) throws -> [String] {
        let files = FileManager.default
        let list = tree.appendingPathComponent(listPath)
        guard let text = try? String(contentsOf: list, encoding: .utf8) else {
            throw StepFailure.recipe("SCUMMVM.KEEP-DATA: there's no ScummVM engine in this stage (USE scummvm first)")
        }
        let paths = text.split(separator: "\n").map(String.init)
        // Each path's name in Resources: its first part there.
        func name(_ path: String) -> String? {
            guard path.hasPrefix("Resources/"), !path.hasPrefix("Resources/engines/") else { return nil }
            return path.dropFirst("Resources/".count).split(separator: "/").first.map(String.init)
        }
        let names = Set(paths.compactMap(name))
        let missing = kept.subtracting(names).sorted()
        guard missing.isEmpty else {
            throw StepFailure.recipe("SCUMMVM.KEEP-DATA: this ScummVM has no \(missing.joined(separator: ", "))")
        }
        let going = names.subtracting(kept).subtracting(alwaysKept)
        for gone in going.sorted() {
            let url = tree.appendingPathComponent("Contents/Resources").appendingPathComponent(gone)
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        }
        let left = paths.filter { name($0).map { !going.contains($0) } ?? true }
        try Data((left.joined(separator: "\n") + "\n").utf8).write(to: list)
        return going.sorted()
    }
}
