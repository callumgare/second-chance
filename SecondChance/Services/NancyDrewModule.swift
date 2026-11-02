//
//  NancyDrewModule.swift
//  SecondChance
//
//  The nancy-drew module's data and assets, as Second Chance ships them.

import Foundation
import WrappBuilder

/// What every Nancy Drew game shares, from the `nancy-drew` module in Second
/// Chance's resources (`Modules/nancy-drew`, docs/modules.md): Her
/// Interactive's patches, the AutoIt scripts that click through its
/// installers and patchers, and the settings its games' .ini files get.
nonisolated enum NancyDrewModule {
    /// The module's folder in `bundle`'s resources.
    static func folder(in bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent("Modules/nancy-drew")
    }

    /// One of the module's AutoIt scripts (`assets/<name>.au3`), if it has it.
    static func autoItScript(_ name: String, in bundle: Bundle = .main) -> URL? {
        guard let script = folder(in: bundle)?.appendingPathComponent("assets/\(name).au3"),
              FileManager.default.fileExists(atPath: script.path) else { return nil }
        return script
    }

    /// The patch list (`patches.json`).
    static func patchesManifest(in bundle: Bundle = .main) -> URL? {
        folder(in: bundle)?.appendingPathComponent("patches.json")
    }

    /// What a game's .ini files have changed after it installs (`ini.yaml`).
    struct IniSettings: Decodable {
        let replace: [Replacement]?
        let set: [Setting]?

        struct Replacement: Decodable {
            let from: String
            let to: String
            /// What says the file has it already, for the log.
            let already: String?
        }

        struct Setting: Decodable {
            let key: String
            let value: String
        }
    }

    static func iniSettings(in bundle: Bundle = .main) throws -> IniSettings {
        guard let folder = folder(in: bundle) else { throw CocoaError(.fileNoSuchFile) }
        let loader = try ModuleLoader(root: folder.deletingLastPathComponent())
        guard let module = loader.module("nancy-drew") else { throw CocoaError(.fileReadCorruptFile) }
        return try ModuleLoader.table("ini.yaml", of: module, as: IniSettings.self)
    }
}

/// Downloads Second Chance ships, by their sha256: the archives a build
/// needs, staged at build time (`setup-game-patches.sh`) so a wrapp build
/// downloads nothing it can get from here.
nonisolated enum DownloadCache {
    /// The shipped copy of the download with `sha256`, if Second Chance has one.
    static func shipped(sha256: String, in bundle: Bundle = .main) -> URL? {
        guard let file = bundle.resourceURL?.appendingPathComponent("downloads/\(sha256.lowercased())"),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
}

/// The program bundles Second Chance ships (`Contents/Resources/Bundles`,
/// docs/program-bundles.md).
nonisolated enum ShippedBundles {
    /// A file in the assets of the Nancy Drew game `slug`'s bundle, if it has it.
    static func asset(_ name: String, ofGame slug: String, in bundle: Bundle = .main) -> URL? {
        guard let file = bundle.resourceURL?.appendingPathComponent("Bundles/nancy-drew/\(slug)/assets/\(name)"),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
}
