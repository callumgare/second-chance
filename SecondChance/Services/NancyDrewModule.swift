//
//  NancyDrewModule.swift
//  SecondChance
//
//  The nancy-drew module's data and assets, as Second Chance ships them.

import Foundation
import WrappBuilder
import SecondChanceKit

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
    /// What building `edition` of the Nancy Drew game `slug` runs, from its
    /// shipped bundle, Wrappfile and the shipped modules; nil for an edition
    /// with no stage of its own. Throws `buildRecipeProblem` when the bundle
    /// can't be loaded or planned.
    static func plan(forGame slug: String, edition: String, in bundle: Bundle = .main) throws -> BuildPlan? {
        guard let resources = bundle.resourceURL else { throw WrappBuildError.buildRecipeProblem("no resources") }
        do {
            let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules")).loadAll().get()
            let folder = resources.appendingPathComponent("Bundles/nancy-drew/\(slug)")
            let loaded = try ProgramBundleLoader(root: resources.appendingPathComponent("Bundles"), modules: modules).load(folder).get()
            let wrappfile = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
            return try BuildPlanner(bundle: loaded, wrappfile: wrappfile, modules: modules).plan(edition: edition, conditions: .thisMac)
        } catch let error as WrappBuildError {
            throw error
        } catch {
            throw WrappBuildError.buildRecipeProblem("\(slug) \(edition): \(error)")
        }
    }

    /// What a wrapp of `edition` of the game `slug` is built from: its
    /// bundle's version, and the modules its plan's target stage has (or,
    /// for an edition built by a module's own stages, the composition's),
    /// each at the release and version shipped.
    static func lock(forGame slug: String, edition: String, source: WrappSource, composition: Composition,
                     in bundle: Bundle = .main) throws -> WrappLock {
        guard let resources = bundle.resourceURL else { throw WrappBuildError.buildRecipeProblem("no resources") }
        do {
            let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules")).loadAll().get()
            let folder = resources.appendingPathComponent("Bundles/nancy-drew/\(slug)")
            let loaded = try ProgramBundleLoader(root: resources.appendingPathComponent("Bundles"), modules: modules).load(folder).get()
            let planned = try plan(forGame: slug, edition: edition, in: bundle)?.target?.modules
            let used = planned ?? composition.modules.map(\.rawValue)
            let refs = used.compactMap { id in
                modules.first { $0.manifest.id == id }.map {
                    WrappLock.ModuleRef(id: id, release: $0.manifest.release, version: $0.manifest.versions.first?.version)
                }
            }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            return WrappLock(bundle: .init(id: loaded.manifest.id, version: loaded.manifest.version), edition: edition,
                             source: source.rawValue, composition: composition, modules: refs, builtBy: version)
        } catch let error as WrappBuildError {
            throw error
        } catch {
            throw WrappBuildError.buildRecipeProblem("\(slug) \(edition) lock: \(error)")
        }
    }

    /// A file in the assets of the Nancy Drew game `slug`'s bundle, if it has it.
    static func asset(_ name: String, ofGame slug: String, in bundle: Bundle = .main) -> URL? {
        guard let file = bundle.resourceURL?.appendingPathComponent("Bundles/nancy-drew/\(slug)/assets/\(name)"),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
}
