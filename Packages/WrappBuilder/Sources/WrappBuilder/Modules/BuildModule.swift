//
//  BuildModule.swift
//  WrappBuilder
//
//  What each module contributes to building a wrapp.

import Foundation
import WrappModules

/// A module's part in a build that is code: how its engine is prepared,
/// for a module with one. What it declares — its instructions, the options
/// it adds to the core's, its mount fields — is its `module.yaml`'s
/// `build:` (`ModuleDeclarations`), with its versions, functions and tables.
public nonisolated protocol BuildModule: Sendable {
    static var id: ModuleID { get }

    /// Lay an engine version's downloaded sources out as a wrapp's
    /// `Contents/` (`EnginePreparer`), returning the files to sign once the
    /// tree is hashed; only an engine's module has one.
    static func prepare(_ job: EngineJob) async throws -> [URL]
}

nonisolated extension BuildModule {
    public static func prepare(_ job: EngineJob) async throws -> [URL] {
        throw EngineError("the \(id.rawValue) module has no engine to prepare")
    }
}

public nonisolated enum WineBuild: BuildModule {
    public static let id = ModuleID.wine
    /// The wine module's `prefix` stage (`Modules/wine/stages/prefix`), at
    /// the Wine `constraint` picks: what every prefix is made with.
    public static func prefixStage(modules root: URL, constraint: String? = "10") throws -> PlannedStage {
        let modules = try ModuleLoader(root: root).loadAll().get()
        guard let stage = try BuildPlanner.moduleStage(id.rawValue, "prefix", constraint: constraint, modules: modules) else {
            throw ModuleReleases.RecordError(description: "The wine module has no prefix stage")
        }
        return stage
    }
}

public nonisolated enum ScummVMBuild: BuildModule {
    public static let id = ModuleID.scummvm
}

/// DOSBox Staging, which runs a DOS game from its folder, with no Wine.
public nonisolated enum DOSBoxBuild: BuildModule {
    public static let id = ModuleID.dosbox
}

/// Steam is installed into a wrapp's Wine by its build, so the template
/// holds nothing of its.
public nonisolated enum SteamBuild: BuildModule {
    public static let id = ModuleID.steam
}

/// Runs a Windows installer in the stage's Wine: silently with an answer
/// file, and with `--automation=<script>`, under AutoIt, which is given the
/// installer's command and clicks where it stops; the wizard when nobody is
/// there to click is a failure.
public nonisolated enum InstallerBuild: BuildModule {
    public static let id: ModuleID = "installer"
}

/// The person's own disc, brought in as a source input.
public nonisolated enum DiscBuild: BuildModule {
    public static let id: ModuleID = "disc"
}

/// A download from Her Interactive's store: a Windows installer, unpacked
/// and run as a disc's is, or a Mac app whose Windows game is taken out.
public nonisolated enum HerDownloadBuild: BuildModule {
    public static let id: ModuleID = "her-download"
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
    /// types they declare.
    public static func problems(across modules: [ModuleFolder]) -> [String] {
        var problems = PathTypeRegistry(modules: modules).problems
        let ids = modules.map(\.manifest.id)
        for (lowered, same) in Dictionary(grouping: ids, by: { $0.lowercased() }) where same.count > 1 {
            problems.append("modules \(same.sorted().joined(separator: " and ")) differ only in case (\(lowered))")
        }
        return problems.sorted()
    }
}
