//
//  BuildModule.swift
//  WrappBuilder
//
//  What each module contributes to building a wrapp.

import Foundation
import WrappModules

/// A module's part in a build: which of the template's files are its own
/// (removed from a wrapp whose composition doesn't use it), the
/// instructions it adds to a stage that `USE`s it, and the stages it
/// provides (`FROM steam/client`). Its data — versions, functions, tables —
/// is in its folder in `Modules/`; this is its Swift.
public nonisolated protocol BuildModule: Sendable {
    static var id: ModuleID { get }

    /// The list, in the template's Resources, of the files this module owns
    /// in a wrapp (`setup-wine.sh` and `setup-scummvm.sh` write them); nil
    /// for a module with no files of its own in the template.
    static var templateFiles: String? { get }

    /// Its instructions, by name (`MOUNT` for `wine.MOUNT`).
    static var instructions: [InstructionSpec] { get }

    /// The stages it provides, by name (`client` for `FROM steam/client`).
    static var stages: [String] { get }
}

nonisolated extension BuildModule {
    public static var templateFiles: String? { nil }
    public static var instructions: [InstructionSpec] { [] }
    public static var stages: [String] { [] }
}

public nonisolated enum WineBuild: BuildModule {
    public static let id = ModuleID.wine
    public static let templateFiles: String? = "wine-files"
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
        let loader = try ModuleLoader(root: root)
        switch loader.load(root.appendingPathComponent(id.rawValue)) {
        case .success(let module):
            return try ModuleLoader.table("prefix.yaml", of: module, as: PrefixSetup.self)
        case .failure(let problems):
            throw ModuleReleases.RecordError(description: "The wine module has problems: \(problems)")
        }
    }
}

public nonisolated enum ScummVMBuild: BuildModule {
    public static let id = ModuleID.scummvm
    public static let templateFiles: String? = "scummvm-files"
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

    /// The template's file lists of the modules `composition` doesn't run,
    /// by module, whose files are to be removed from its wrapp.
    public static func unusedTemplateFiles(for composition: Composition) -> [(module: ModuleID, list: String)] {
        known.compactMap { module in
            guard !composition.has(module.id), let list = module.templateFiles else { return nil }
            return (module.id, list)
        }
    }
}
