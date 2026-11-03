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

    /// Its instructions, by name (`MOUNT` for `wine.MOUNT`).
    static var instructions: [InstructionSpec] { get }

    /// The stages it provides, by name (`client` for `FROM steam/client`).
    static var stages: [String] { get }

    /// Lay an engine version's downloaded sources out as a wrapp's
    /// `Contents/` (`EnginePreparer`), returning the files to sign once the
    /// tree is hashed; only an engine's module has one.
    static func prepare(_ job: EngineJob) async throws -> [URL]
}

nonisolated extension BuildModule {
    public static var instructions: [InstructionSpec] { [] }
    public static var stages: [String] { [] }

    public static func prepare(_ job: EngineJob) async throws -> [URL] {
        throw EngineError("the \(id.rawValue) module has no engine to prepare")
    }
}

public nonisolated enum WineBuild: BuildModule {
    public static let id = ModuleID.wine
    public static let instructions = [
        // Installs a winetricks verb.
        InstructionSpec("WINETRICKS", arguments: 1...1),
        // Sets (`--set <key>:<name> <value>`) or removes (`--remove <key>:<name>`) a registry value.
        InstructionSpec("REGISTRY", options: ["set": .flag, "remove": .flag], arguments: 1...2),
        // Gives a folder in the prefix a drive, kept for later steps and at launch.
        InstructionSpec("MOUNT", options: ["cdrom": .flag], arguments: 2...2),
        // Copies every disc the edition declares into `--into` (`<into>/disk-<n>`),
        // and for more than one disc merges them into `--combined` as well, giving
        // each a drive from D: in order: for a game that checks for its disc.
        InstructionSpec("KEEP-DISCS", options: ["into": .value, "combined": .value], required: ["into"]),
    ]

    /// How the wine module sets a new prefix up, after wineboot
    /// (`Modules/wine/prefix.yaml`), in order.
    public struct PrefixSetup: Decodable, Sendable {
        public let setup: [Step]

        /// One step: exactly one of its actions, which the schema checks.
        public struct Step: Decodable, Sendable {
            public let registry: RegistryValue?
            public let winetricks: String?
            public let ddrawIni: [String: String]?
            /// What the build's progress says meanwhile: display, graphics or disc.
            public let progress: String?
        }

        public struct RegistryValue: Decodable, Sendable {
            /// x11-driver, mac-driver or direct3d.
            public let key: String
            public let name: String
            public let value: String
        }
    }

    /// The prefix set-up in the wine module in `modules`.
    public static func prefixSetup(modules root: URL) throws -> PrefixSetup {
        try ModuleLoader.table("prefix.yaml", of: module(in: root), as: PrefixSetup.self)
    }

    static func module(in root: URL) throws -> ModuleFolder {
        let loader = try ModuleLoader(root: root)
        switch loader.load(root.appendingPathComponent(id.rawValue)) {
        case .success(let module):
            return module
        case .failure(let problems):
            throw ModuleReleases.RecordError(description: "The wine module has problems: \(problems)")
        }
    }

    /// Raised whenever the Swift that makes a prefix (`WineManager`'s
    /// `makeWinePrefix`) changes what it makes: the one input of the prefix
    /// layer's key that can't be read from a file.
    public static let prefixCodeRevision = 1

    /// The key of the layer a new prefix is (`USE wine`): the engine, the
    /// wine module's release and the set-up it follows, and winetricks.
    /// A change to any of them makes a fresh prefix, with nothing to clear.
    public static func prefixLayerKey(engineVersion: String, modules root: URL, winetricks: URL?) throws -> LayerKey {
        let module = try module(in: root)
        return LayerKey(slot: "wine prefix", inputs: [
            .init("wine engine", engineVersion.trimmingCharacters(in: .whitespacesAndNewlines)),
            .init("wine release", String(module.manifest.release)),
            .init("wine prefix.yaml", try LayerKey.hash(file: module.file("prefix.yaml"))),
            .init("winetricks", try winetricks.map(LayerKey.hash(file:)) ?? "none"),
            .init("prefix code revision", String(prefixCodeRevision)),
        ])
    }
}

public nonisolated enum ScummVMBuild: BuildModule {
    public static let id = ModuleID.scummvm
}

/// Steam is installed into a wrapp's Wine by its build, so the template
/// holds nothing of its.
public nonisolated enum SteamBuild: BuildModule {
    public static let id = ModuleID.steam
    public static let instructions = [
        // Installs the input's app (`steam.INSTALL game --into=…`), the sign-in mounted as a secret.
        InstructionSpec("INSTALL", options: ["into": .value], required: ["into"], arguments: 1...1, firstArgumentIsInput: true),
    ]
    /// `client`: Steam installed in a prefix and signed in.
    public static let stages = ["client"]
}

/// Runs a Windows installer in the stage's Wine: silently with an answer
/// file, or watched and closed when it won't exit by itself, or under
/// AutoIt; the wizard when nobody is there to click is a failure.
public nonisolated enum InstallerBuild: BuildModule {
    public static let id: ModuleID = "installer"
    public static let instructions = [
        // `installer.RUN --from=disc-1 [program]`: the installer on the input (found
        // as GameDetector finds it when no program is named), into `--into`.
        InstructionSpec("RUN", options: ["from": .value, "into": .value, "answer-file": .value, "stubborn": .flag,
                                         "driver": .value, "msi-properties": .value, "mount": .repeated],
                        required: ["into"], arguments: 0...Int.max),
    ]
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
        // `her-download.INSTALL installer [--into=…] [--answer-file=…]`: where the
        // download's installer puts the game when `--into` is left out.
        InstructionSpec("INSTALL", options: ["into": .value, "answer-file": .value], arguments: 1...1, firstArgumentIsInput: true),
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
        WineBuild.self, ScummVMBuild.self, SteamBuild.self, BigFishBuild.self, InstallerBuild.self, DiscBuild.self,
        HerDownloadBuild.self,
    ]

    /// The Swift of the module whose `native:` is `id`.
    public static func native(_ id: String) -> (any BuildModule.Type)? {
        known.first { $0.id.rawValue == id }
    }
}
