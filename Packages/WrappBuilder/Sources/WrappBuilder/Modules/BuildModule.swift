//
//  BuildModule.swift
//  WrappBuilder
//
//  What each module contributes to building a wrapp.

import Foundation
import WrappModules

/// A module's part in a build: how its engine is prepared, for a module
/// with one, the instructions it adds to a stage that `USE`s it, and the
/// stages it provides (`FROM steam/client`). Its data — versions, functions, tables —
/// is in its folder in `Modules/`; this is its Swift.
public nonisolated protocol BuildModule: Sendable {
    static var id: ModuleID { get }

    /// Its instructions, by name (`MOUNT` for `WINE.MOUNT`).
    static var instructions: [InstructionSpec] { get }

    /// The stages it provides, by name (`client` for `FROM steam/client`).
    static var stages: [String] { get }

    /// Options it adds to core instructions, by instruction, each written
    /// `--<alias>.<option>` in a stage that has the module.
    static var coreOptions: [String: [String: InstructionSpec.OptionKind]] { get }

    /// What each of those options' values is, where it isn't text: by
    /// instruction, then option (`LAUNCH`'s `exe`, a location).
    static var coreOptionRoles: [String: [String: InstructionSpec.Role]] { get }

    /// Fields it adds to core mount types, by type, each written
    /// `<alias>.<field>=…` in a `--mount=`.
    static var mountFields: [String: Set<String>] { get }

    /// Files its Swift provides rather than its folder, which a Wrappfile
    /// names as `module:<id>/<path>` (the installer module's `autoit`).
    static var providedFiles: Set<String> { get }

    /// Lay an engine version's downloaded sources out as a wrapp's
    /// `Contents/` (`EnginePreparer`), returning the files to sign once the
    /// tree is hashed; only an engine's module has one.
    static func prepare(_ job: EngineJob) async throws -> [URL]
}

nonisolated extension BuildModule {
    public static var instructions: [InstructionSpec] { [] }
    public static var stages: [String] { [] }
    public static var coreOptions: [String: [String: InstructionSpec.OptionKind]] { [:] }
    public static var coreOptionRoles: [String: [String: InstructionSpec.Role]] { [:] }
    public static var mountFields: [String: Set<String>] { [:] }
    public static var providedFiles: Set<String> { [] }

    public static func prepare(_ job: EngineJob) async throws -> [URL] {
        throw EngineError("the \(id.rawValue) module has no engine to prepare")
    }
}

public nonisolated enum WineBuild: BuildModule {
    public static let id = ModuleID.wine
    public static let instructions = [
        // Installs a winetricks verb.
        InstructionSpec("WINETRICKS", arguments: 1...1),
        // The prefix's drives: `--only=C:` removes every other, C: at drive_c,
        // the rest blocked (Z:, the whole Mac, included).
        InstructionSpec("DRIVES", options: ["only": .value], required: ["only"]),
        // Sets (`--set <key>:<name> <value>`) or removes (`--remove <key>:<name>`) a registry value.
        InstructionSpec("REGISTRY", options: ["set": .flag, "remove": .flag], arguments: 1...2),
        // Gives a folder in the prefix a drive, kept for later steps and at launch.
        InstructionSpec("MOUNT", options: ["cdrom": .flag], arguments: 2...2, argumentRoles: [.location, .text]),
        // Copies the discs it's given into `--into` (`<into>/disk-<n>`), and for
        // more than one merges them into `--combined` as well, giving each a
        // drive from D: in order: for a game that checks for its disc.
        InstructionSpec("KEEP-DISCS", options: ["into": .value, "combined": .value], required: ["into"],
                        arguments: 1...Int.max, argumentRoles: [.input],
                        optionRoles: ["into": .location, "combined": .location]),
    ]

    /// A `source` mount's drive: `--mount=type=source,from=disc-1,wine.drive=D:`.
    public static let mountFields = ["source": Set(["drive"])]

    /// A launch's: what the program draws with (`direct-draw`, `direct-3d` or
    /// `unknown`), and the log and line that say a non-zero exit was a clean
    /// quit. A volume's: the drive it's given.
    public static let coreOptions: [String: [String: InstructionSpec.OptionKind]] = [
        "LAUNCH": ["graphics": .value, "clean-exit-log": .value, "clean-exit-line": .value],
        "VOLUME": ["drive": .value],
    ]

    /// The wine module's `prefix` stage (`Modules/wine/stages/prefix`), at
    /// the Wine `constraint` picks: what every prefix is made with.
    public static func prefixStage(modules root: URL, constraint: String? = "10") throws -> PlannedStage {
        let modules = try ModuleLoader(root: root).loadAll().get()
        guard let stage = try BuildPlanner.moduleStage(id.rawValue, "prefix", constraint: constraint, modules: modules) else {
            throw ModuleReleases.RecordError(description: "The wine module has no prefix stage")
        }
        return stage
    }

    /// Raised whenever the Swift that makes a prefix (`WineManager`'s
    /// `makeWinePrefix`, and how it carries out the stage's steps) changes
    /// what it makes: the one input of the prefix layer's key that can't be
    /// read from a file.
    public static let prefixCodeRevision = 2

    /// The key of the layer a new prefix is: the engine, the `prefix`
    /// stage's steps as planned, and winetricks. A change to any of them
    /// makes a fresh prefix, with nothing to clear.
    public static func prefixLayerKey(engineVersion: String, stage: PlannedStage, winetricks: URL?) throws -> LayerKey {
        LayerKey(slot: "wine prefix", inputs: [
            .init("wine engine", engineVersion.trimmingCharacters(in: .whitespacesAndNewlines)),
            .init("wine prefix stage", stage.steps.map(\.description).joined(separator: "\n")),
            .init("winetricks", try winetricks.map(LayerKey.hash(file:)) ?? "none"),
            .init("prefix code revision", String(prefixCodeRevision)),
        ])
    }
}

public nonisolated enum ScummVMBuild: BuildModule {
    public static let id = ModuleID.scummvm
}

/// DOSBox Staging, which runs a DOS game from its folder, with no Wine.
public nonisolated enum DOSBoxBuild: BuildModule {
    public static let id = ModuleID.dosbox
    /// A volume laid over a drive the game sees (`mount c … -t overlay`),
    /// holding what the game writes.
    public static let coreOptions: [String: [String: InstructionSpec.OptionKind]] = ["VOLUME": ["overlay": .flag]]
}

/// Steam is installed into a wrapp's Wine by its build, so the template
/// holds nothing of its.
public nonisolated enum SteamBuild: BuildModule {
    public static let id = ModuleID.steam
    public static let instructions = [
        // Installs Steam's client in the prefix.
        InstructionSpec("CLIENT"),
        // Has Steam install the input's app (`STEAM.INSTALL game --into=…`), with
        // the shared sign-in (a `secret` mount) and the cached client (a `cache`
        // one), and makes `--into` a link to the folder Steam put it in.
        InstructionSpec("INSTALL", options: ["into": .value, "mount": .repeated], required: ["into"], arguments: 1...1,
                        argumentRoles: [.input], optionRoles: ["into": .location]),
        // Takes the sign-in out of the prefix, saved to the shared store first.
        InstructionSpec("SIGN-OUT"),
        // Takes Steam away: the game moved to where `STEAM.INSTALL --into` linked
        // it, then Steam's folders and its registry settings removed.
        InstructionSpec("REMOVE"),
    ]

    /// A launch's: the program Steam starts (`--steam.exe=C:/…/Game.exe`),
    /// which the app finds the game's process by.
    public static let coreOptions: [String: [String: InstructionSpec.OptionKind]] = ["LAUNCH": ["exe": .value]]
    public static let coreOptionRoles: [String: [String: InstructionSpec.Role]] = ["LAUNCH": ["exe": .location]]
}

/// Runs a Windows installer in the stage's Wine: silently with an answer
/// file, and with `--automation=<script>`, under AutoIt, which is given the
/// installer's command and clicks where it stops; the wizard when nobody is
/// there to click is a failure.
public nonisolated enum InstallerBuild: BuildModule {
    public static let id: ModuleID = "installer"
    public static let instructions = [
        // `INSTALLER.RUN --from=${input.disc-1} [program]`: the installer on the input
        // (found as GameDetector finds it when no program is named), into `--into`.
        InstructionSpec("RUN", options: ["from": .value, "into": .value, "answer-file": .value, "automation": .value,
                                         "creates": .value, "patch": .flag, "driver": .value, "msi-properties": .value, "mount": .repeated],
                        required: ["into"], arguments: 0...Int.max, argumentRoles: [.program, .text],
                        optionRoles: ["from": .input, "into": .location, "answer-file": .file, "automation": .file,
                                      "creates": .location]),
    ]
    /// AutoIt, which Second Chance carries: `module:installer/autoit`.
    public static let providedFiles: Set<String> = ["autoit"]
}

/// The person's own disc, brought in as a source input.
public nonisolated enum DiscBuild: BuildModule {
    public static let id: ModuleID = "disc"
}

/// A download from Her Interactive's store: a Windows installer, unpacked
/// and run as a disc's is, or a Mac app whose Windows game is taken out.
public nonisolated enum HerDownloadBuild: BuildModule {
    public static let id: ModuleID = "her-download"
    public static let instructions = [
        // `HER-DOWNLOAD.INSTALL installer [--into=…] [--answer-file=…]`: where the
        // download's installer puts the game when `--into` is left out.
        InstructionSpec("INSTALL", options: ["into": .value, "answer-file": .value, "automation": .value, "creates": .value],
                        arguments: 1...1, argumentRoles: [.input],
                        optionRoles: ["into": .location, "answer-file": .file, "automation": .file, "creates": .location]),
    ]
}

/// Big Fish's Game Manager is installed into a wrapp's Wine by its build,
/// so the template holds nothing of its either. Its editions name no
/// stage: `BigFishWrappBuilder` builds them, as Steam's builder does its.
public nonisolated enum BigFishBuild: BuildModule {
    public static let id = ModuleID.bigFish
}

public nonisolated enum BuildModules {
    /// Every module a build knows.
    public static let known: [any BuildModule.Type] = [
        WineBuild.self, ScummVMBuild.self, DOSBoxBuild.self, SteamBuild.self, BigFishBuild.self, InstallerBuild.self,
        DiscBuild.self,
        HerDownloadBuild.self,
    ]

    /// The Swift of the module whose `native:` is `id`.
    public static func native(_ id: String) -> (any BuildModule.Type)? {
        known.first { $0.id.rawValue == id }
    }

    /// What's wrong across modules rather than in one: two whose ids differ
    /// only in case (a module's name is case-insensitive), and the path
    /// types they register.
    public static func problems(across modules: [ModuleFolder], pathTypes: PathTypeRegistry = .shipped) -> [String] {
        var problems = pathTypes.problems
        let ids = modules.map(\.manifest.id)
        for (lowered, same) in Dictionary(grouping: ids, by: { $0.lowercased() }) where same.count > 1 {
            problems.append("modules \(same.sorted().joined(separator: " and ")) differ only in case (\(lowered))")
        }
        return problems.sorted()
    }
}
