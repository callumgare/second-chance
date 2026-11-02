//
//  BuildModule.swift
//  WrappBuilder
//
//  What each module contributes to building a wrapp.

import Foundation
import WrappModules

/// A module's part in a build. For now, only what today's builders ask of
/// it: which of the template's files are its own, removed from a wrapp
/// whose composition doesn't use it. The Wrappfile builder adds what a
/// stage that `USE`s it does (its base layer, its instructions, running
/// programs).
public nonisolated protocol BuildModule {
    static var id: ModuleID { get }

    /// The list, in the template's Resources, of the files this module owns
    /// in a wrapp (`setup-wine.sh` and `setup-scummvm.sh` write them); nil
    /// for a module with no files of its own in the template.
    static var templateFiles: String? { get }
}

public nonisolated enum WineBuild: BuildModule {
    public static let id = ModuleID.wine
    public static let templateFiles: String? = "wine-files"

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
    public static let templateFiles: String? = nil
}

/// Big Fish's Game Manager is installed into a wrapp's Wine by its build,
/// so the template holds nothing of its either.
public nonisolated enum BigFishBuild: BuildModule {
    public static let id = ModuleID.bigFish
    public static let templateFiles: String? = nil
}

public nonisolated enum BuildModules {
    /// Every module a build knows.
    public static let known: [any BuildModule.Type] = [WineBuild.self, ScummVMBuild.self, SteamBuild.self, BigFishBuild.self]

    /// The template's file lists of the modules `composition` doesn't run,
    /// by module, whose files are to be removed from its wrapp.
    public static func unusedTemplateFiles(for composition: Composition) -> [(module: ModuleID, list: String)] {
        known.compactMap { module in
            guard !composition.has(module.id), let list = module.templateFiles else { return nil }
            return (module.id, list)
        }
    }
}
