//
//  WineExecutor.swift
//  WineExecutor
//
//  The wine module's executor: its instructions, carried out in a tree's
//  prefix, and the Windows programs a build runs.

import Foundation
import Logging
import WineKit
import WrappFormat
import WrappModuleKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.WineExecutor")

/// Carries out `WINE.DRIVES`, `REGISTRY`, `WINETRICKS` and `MOUNT`, and its
/// setup steps `HELPERS` and `PREFIX`, in the step's tree, and runs a
/// `wine:` program for `RUN` (docs/modules.md#executors). Portable: it needs
/// nothing of Second Chance's.
public nonisolated struct WineExecutor: ModuleExecutor {
    public static let handles = ["DRIVES", "REGISTRY", "WINETRICKS", "MOUNT", "HELPERS", "PREFIX"]

    /// The winetricks it runs; nil for the module's own.
    let winetricks: URL?
    /// The in-process helpers `HELPERS` lays in, when the caller has them.
    let helpers: URL?
    /// The longest a `RUN` of a Windows program may take.
    let programTimeout: TimeInterval
    /// The prepared engine's `build-tools` for the tree, which winetricks
    /// finds cabextract in.
    let buildTools: @Sendable (URL) -> URL?

    public init(winetricks: URL? = nil, helpers: URL? = nil, programTimeout: TimeInterval = 1800,
                buildTools: @escaping @Sendable (URL) -> URL? = { _ in nil }) {
        self.buildTools = buildTools
        self.winetricks = winetricks
        self.helpers = helpers
        self.programTimeout = programTimeout
    }

    public func run(_ step: PlannedStep, in context: any StepContext) async throws {
        let wine = Wine(wrapp: context.tree)
        switch step.instruction {
        case "DRIVES":
            // C: at drive_c, relative so the prefix still works copied into a
            // wrapp, and every other drive blocked: Z: shows the whole Mac.
            guard step.option("only") == "C:" else {
                throw StepFailure.recipe("\(step.origin): this build keeps only C: (WINE.DRIVES --only=C:)")
            }
            wine.drives.removeAll()
            try wine.drives.mount("../drive_c", as: "c")
            wine.drives.block("abdefghijklmnopqrstuvwxyz")
        case "REGISTRY":
            guard let target = step.arguments.first, let colon = target.lastIndex(of: ":") else {
                throw StepFailure.recipe("\(step.origin): WINE.REGISTRY names <key>:<name>")
            }
            let key = Self.registryKey(String(target[..<colon]))
            let name = String(target[target.index(after: colon)...])
            if step.has("remove") {
                try await wine.registry.deleteValue(name, in: key)
            } else {
                guard step.arguments.count == 2 else { throw StepFailure.recipe("\(step.origin): WINE.REGISTRY --set needs the value") }
                try await wine.registry.set(.string(step.arguments[1]), for: name, in: key)
            }
        case "WINETRICKS":
            guard let verb = step.arguments.first else { return }
            try await Winetricks(wine: wine, script: winetricks, tools: buildTools(context.tree)).install(verb)
        case "MOUNT":
            // A folder of the tree's given a drive, kept for later steps and at launch.
            guard step.arguments.count == 2, let folder = WrappLayout(app: context.tree).location(step.arguments[0]),
                  let letter = step.arguments[1].lowercased().first, step.arguments[1].count <= 2 else {
                throw StepFailure.recipe("\(step.origin): WINE.MOUNT takes a folder in the prefix and a drive letter")
            }
            try wine.drives.mount(folder, as: letter)
            if step.has("cdrom") { try await wine.drives.setKind(.cdrom, of: letter) }
        case "HELPERS":
            try layInHelpers(in: context.tree, step: step)
        case "PREFIX":
            // wineboot's prefix, Wine's server let finish so it's all written.
            try await wine.run(.wine(["wineboot", "-u"]))
            try await wine.server.waitUntilProgramsExit(timeout: nil)
        default:
            throw StepFailure.recipe("\(step.origin): the wine module has no instruction \(step.instruction)")
        }
        logger.notice("✓ \(step)")
    }

    /// A `wine:` program, its arguments in Windows's style, run in the
    /// tree's Wine with its environment, its exit code returned.
    public func runProgram(_ program: ProgramRun, in context: any StepContext) async throws -> Int32 {
        let path = program.program.hasPrefix("wine:") ? String(program.program.dropFirst("wine:".count)) : program.program
        let arguments = program.arguments.map(Self.windowsStyle)
        let wine = Wine(wrapp: context.tree)
        do {
            try await wine.run(.program(Self.windowsStyle(path), arguments), environment: program.environment,
                               timeout: program.timeout.map { TimeInterval($0.components.seconds) } ?? programTimeout)
            return 0
        } catch WineError.executionFailed(let code) {
            return code
        }
    }

    /// Wine's server let finish, so the registry is written to its files
    /// and nothing is running in the tree.
    public func checkpoint(_ context: any StepContext) async throws {
        try await Wine(wrapp: context.tree).server.waitUntilProgramsExit(timeout: nil)
    }

    /// The helpers the Mac driver loads, laid in the tree's `Frameworks/`.
    func layInHelpers(in tree: URL, step: PlannedStep) throws {
        guard let helpers else {
            throw StepFailure.recipe("\(step.origin): this build has no in-process helpers to lay in")
        }
        let target = WrappLayout(app: tree).frameworks.appendingPathComponent(helpers.lastPathComponent)
        let files = FileManager.default
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
        try files.copyItem(at: helpers, to: target)
    }

    /// A registry key the wine module's steps name: in full
    /// (`HKEY_CURRENT_USER\Software\Wine\…`), or by a short name.
    public static func registryKey(_ name: String) -> WineRegistry.Key {
        if name.hasPrefix("HKEY_") { return WineRegistry.Key(rawValue: name) }
        return switch name {
        case "mac-driver": #"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#
        case "direct3d": #"HKEY_CURRENT_USER\Software\Wine\Direct3D"#
        default: .x11Driver
        }
    }

    /// `C:/a/b` as `C:\a\b`; anything else as it is.
    public static func windowsStyle(_ argument: String) -> String {
        let letters = argument.prefix(3)
        guard letters.count == 3, letters.first?.isLetter == true, letters.dropFirst().first == ":",
              letters.last == "/" else { return argument }
        return argument.replacingOccurrences(of: "/", with: "\\")
    }
}
