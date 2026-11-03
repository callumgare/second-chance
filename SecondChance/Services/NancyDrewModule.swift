//
//  NancyDrewModule.swift
//  SecondChance
//
//  The nancy-drew module's data and assets, as Second Chance ships them.

import Foundation
import GameCatalog
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
    /// The program bundle id of the game `slug`: `nancy-drew/<slug>`, or
    /// its own for a program beyond Nancy Drew.
    static func programID(_ slug: String) -> String {
        GameInfoProvider.shared.gameInfo(for: slug).programID
    }

    /// What building `edition` of the Nancy Drew game `slug` runs, from its
    /// shipped bundle, Wrappfile and the shipped modules; nil for an edition
    /// with no stage of its own. Throws `buildRecipeProblem` when the bundle
    /// can't be loaded or planned.
    static func plan(forGame slug: String, edition: String, in bundle: Bundle = .main) throws -> BuildPlan? {
        guard let resources = bundle.resourceURL else { throw WrappBuildError.buildRecipeProblem("no resources") }
        do {
            let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules")).loadAll().get()
            let folder = resources.appendingPathComponent("Bundles/" + programID(slug))
            let loaded = try ProgramBundleLoader(root: resources.appendingPathComponent("Bundles"), modules: modules).load(folder).get()
            let wrappfile = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
            return try BuildPlanner(bundle: loaded, wrappfile: wrappfile, modules: modules).plan(edition: edition, conditions: .thisMac)
        } catch let error as WrappBuildError {
            throw error
        } catch {
            throw WrappBuildError.buildRecipeProblem("\(slug) \(edition): \(error)")
        }
    }

    /// The revision of the launcher this Second Chance's template is
    /// (`stamp-launcher-revision.sh`), which the wrapps it builds carry.
    static func launcherRevision(in bundle: Bundle = .main) -> String? {
        guard let template = bundle.url(forResource: "WrappTemplate", withExtension: "app") else { return nil }
        return Bundle(url: template)?.object(forInfoDictionaryKey: "SecondChanceLauncherRevision") as? String
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
            let folder = resources.appendingPathComponent("Bundles/" + programID(slug))
            let loaded = try ProgramBundleLoader(root: resources.appendingPathComponent("Bundles"), modules: modules).load(folder).get()
            let planned = try plan(forGame: slug, edition: edition, in: bundle)?.target?.modules
            let used = planned ?? composition.modules.map(\.rawValue)
            // Each module's data files by hash, which its default updates
            // compare (`when-changed`).
            let refs = try used.compactMap { id -> WrappLock.ModuleRef? in
                guard let module = modules.first(where: { $0.manifest.id == id }) else { return nil }
                let files = try (module.manifest.data ?? []).reduce(into: [String: String]()) { files, name in
                    files[name] = try LayerKey.hash(file: module.file(name))
                }
                return WrappLock.ModuleRef(id: id, release: module.manifest.release, version: module.manifest.versions.first?.version,
                                           files: files.isEmpty ? nil : files, package: module.manifest.package()?.package.prepared)
            }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            // The volumes of the variant the wrapp runs: its launcher's.
            let manifest = loaded.manifest
            let variant = manifest.variants?.first { $0.id == composition.launcher.rawValue }
                ?? manifest.variants?.first { $0.id == "wine" && composition.has(.wine) }
            let rules = (manifest.volumes ?? [:]).sorted { $0.key < $1.key }.map { name, volume -> VolumeRule in
                switch volume.inUseWhen {
                case .patterns(let patterns): VolumeRule(name: name, patterns: patterns)
                case .never: VolumeRule(name: name, patterns: [])
                case .anyFile, nil: VolumeRule(name: name, patterns: nil)
                }
            }
            let mounted = variant?.volumes?.map(\.source) ?? []
            var lock = WrappLock(bundle: .init(id: manifest.id, version: manifest.version), edition: edition,
                                 source: source.rawValue, composition: composition, modules: refs, builtBy: version,
                                 formerBundleIDs: manifest.formerBundleIds, volumes: rules.isEmpty ? nil : rules,
                                 savesVolume: mounted.first,
                                 scummvmSettingsVolume: mounted.contains("scummvm-settings") ? "scummvm-settings" : nil)
            let wrappfile = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
            let args = BuildPlanner(bundle: loaded, wrappfile: wrappfile, modules: modules).globalConstants(edition: edition)
            lock.args = args.isEmpty ? nil : args
            lock.launcher = launcherRevision(in: bundle)
            return lock
        } catch let error as WrappBuildError {
            throw error
        } catch {
            throw WrappBuildError.buildRecipeProblem("\(slug) \(edition) lock: \(error)")
        }
    }

    /// How to bring the old wrapp `old` locks up to what this Second Chance
    /// builds for the Nancy Drew game `slug`: the lock it would write is the
    /// target, and the bundle's and modules' updates the way there
    /// (`UpdatePlanner`). Throws `buildRecipeProblem` when the bundle can't
    /// be loaded or planned.
    static func updateDecision(from old: WrappLock, forGame slug: String, source: WrappSource, composition: Composition,
                               in bundle: Bundle = .main) throws -> (decision: UpdatePlanner.Decision, target: WrappLock) {
        guard let resources = bundle.resourceURL else { throw WrappBuildError.buildRecipeProblem("no resources") }
        let target = try lock(forGame: slug, edition: old.edition, source: source, composition: composition, in: bundle)
        do {
            let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules")).loadAll().get()
            let folder = resources.appendingPathComponent("Bundles/" + programID(slug))
            let loaded = try ProgramBundleLoader(root: resources.appendingPathComponent("Bundles"), modules: modules).load(folder).get()
            let wrappfile = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
            let planner = BuildPlanner(bundle: loaded, wrappfile: wrappfile, modules: modules)
            let edition = old.edition
            let updates = UpdatePlanner(manifest: loaded.manifest, modules: modules) { stage in
                try planner.plan(edition: edition, target: stage, conditions: .thisMac).target?.modules ?? []
            }
            let decision = try updates.plan(old: old, target: .init(
                bundleVersion: target.bundle.version, edition: target.edition, modules: target.modules, args: target.args ?? [:],
                launcher: target.launcher
            ))
            return (decision, target)
        } catch let error as WrappBuildError {
            throw error
        } catch {
            throw WrappBuildError.buildRecipeProblem("\(slug) update from \(old.summary): \(error)")
        }
    }

    /// The stage `stage` of `edition` of the Nancy Drew game `slug`, planned
    /// for an update that applies `updates`, with `previous` read from the
    /// old wrapp's lock.
    static func plan(forGame slug: String, edition: String, stage: String, updates: [String], previous: [String: String],
                     in bundle: Bundle = .main) throws -> BuildPlan {
        guard let resources = bundle.resourceURL else { throw WrappBuildError.buildRecipeProblem("no resources") }
        do {
            let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules")).loadAll().get()
            let folder = resources.appendingPathComponent("Bundles/" + programID(slug))
            let loaded = try ProgramBundleLoader(root: resources.appendingPathComponent("Bundles"), modules: modules).load(folder).get()
            let wrappfile = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
            var conditions = BuildConditions.thisMac
            conditions.updates = updates
            conditions.previous = previous
            return try BuildPlanner(bundle: loaded, wrappfile: wrappfile, modules: modules).plan(edition: edition, target: stage, conditions: conditions)
        } catch {
            throw WrappBuildError.buildRecipeProblem("\(slug) \(edition) \(stage): \(error)")
        }
    }

    /// A download edition a shipped bundle has: what the download source
    /// offers.
    struct DownloadEdition: Sendable {
        let game: GameInfo
        let edition: String
        let licence: Manifest.Licence
        let licenceFrom: String?
        let licenceFile: String?
        let input: Manifest.Input
        /// Where its Wrappfile installs it (its global `ARG install-dir`).
        let installDir: String?
    }

    /// Every shipped bundle's download editions, in the catalogue's order.
    static func downloadEditions(in bundle: Bundle = .main) throws -> [DownloadEdition] {
        guard let resources = bundle.resourceURL else { throw WrappBuildError.buildRecipeProblem("no resources") }
        let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules")).loadAll().get()
        let loader = try ProgramBundleLoader(root: resources.appendingPathComponent("Bundles"), modules: modules)
        return try GameInfoProvider.shared.allGames().flatMap { game -> [DownloadEdition] in
            let folder = resources.appendingPathComponent("Bundles/" + game.programID)
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.yaml").path) else { return [] }
            let bundle = try loader.load(folder).get()
            let wrappfile = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
            let planner = BuildPlanner(bundle: bundle, wrappfile: wrappfile, modules: modules)
            return bundle.manifest.editions.compactMap { edition in
                guard edition.source == .download, let licence = edition.licence, let input = edition.inputs?.first else { return nil }
                return DownloadEdition(game: game, edition: edition.id, licence: licence, licenceFrom: edition.licenceFrom,
                                       licenceFile: edition.licenceFile, input: input,
                                       installDir: planner.globalConstants(edition: edition.id)["install-dir"])
            }
        }
    }

    /// A file in the assets of the Nancy Drew game `slug`'s bundle, if it has it.
    static func asset(_ name: String, ofGame slug: String, in bundle: Bundle = .main) -> URL? {
        guard let file = bundle.resourceURL?.appendingPathComponent("Bundles/\(programID(slug))/assets/\(name)"),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
}
