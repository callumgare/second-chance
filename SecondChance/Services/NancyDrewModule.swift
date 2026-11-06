//
//  NancyDrewModule.swift
//  SecondChance
//
//  The nancy-drew module's data and assets, as Second Chance ships them.

import Foundation
import GameCatalog
import WrappBuilder
import Logging
import SecondChanceKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.ShippedBundles")

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
    /// The folder of the game `slug`'s bundle: an extra bundle's, when
    /// `sc --bundle` named one with its id (`ExtraBundles`), else the
    /// shipped one's in `resources`.
    static func bundleFolder(ofGame slug: String, resources: URL) -> URL {
        ExtraBundles.folder(of: programID(slug), shippedRoot: resources.appendingPathComponent("Bundles"))
    }

    /// Adds the extra bundles' games (`SECOND_CHANCE_EXTRA_BUNDLES`) to the
    /// catalogue, so a build finds them as it does a shipped game's. At
    /// start-up, before anything asks the catalogue for a game.
    static func addExtraGames(in bundle: Bundle = .main) {
        guard !ExtraBundles.folders().isEmpty, let resources = bundle.resourceURL else { return }
        do {
            let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules"), added: AddedModules.folder()).loadAll().get()
            ExtraBundles.addGames(shippedRoot: resources.appendingPathComponent("Bundles"), modules: modules, places: .shipped)
        } catch {
            logger.error("Couldn't load the modules, so leaving out the extra bundles: \(error)")
        }
    }

    /// The program bundle id of the game `slug`: `nancy-drew/<slug>`, or
    /// its own for a program beyond Nancy Drew.
    static func programID(_ slug: String) -> String {
        GameInfoProvider.shared.gameInfo(for: slug).programID
    }

    /// The edition of `slug`'s bundle a build from `source` makes: the one
    /// edition for that source (decision 20 of the builders plan takes it
    /// from detection's rule where a bundle has more than one), else the
    /// name Second Chance has always given it.
    static func edition(ofGame slug: String, source: WrappSource, in bundle: Bundle = .main) throws -> String {
        guard let resources = bundle.resourceURL else { throw WrappBuildError.buildRecipeProblem("no resources") }
        let kind: Manifest.Source = switch source {
        case .disk: .disc
        case .herDownload: .herDownload
        case .steam: .steam
        case .bigFish: .bigFish
        case .download: .download
        }
        let folder = bundleFolder(ofGame: slug, resources: resources)
        guard let loader = try? ProgramBundleLoader(root: resources.appendingPathComponent("Bundles"), modules: nil),
              let manifest = try? loader.load(folder, anyFolder: true).get().manifest else {
            return WrappBuildHelper.edition(of: source)
        }
        let editions = manifest.editions.filter { $0.source == kind }
        return editions.count == 1 ? editions[0].id : WrappBuildHelper.edition(of: source)
    }

    /// What building `edition` of the Nancy Drew game `slug` runs, from its
    /// shipped bundle, Wrappfile and the shipped modules; nil for an edition
    /// with no stage of its own. Throws `buildRecipeProblem` when the bundle
    /// can't be loaded or planned.
    static func plan(forGame slug: String, edition: String, choices: [String: String] = [:],
                     in bundle: Bundle = .main) throws -> BuildPlan? {
        guard let resources = bundle.resourceURL else { throw WrappBuildError.buildRecipeProblem("no resources") }
        do {
            let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules"), added: AddedModules.folder()).loadAll().get()
            let folder = bundleFolder(ofGame: slug, resources: resources)
            let loaded = try ProgramBundleLoader(root: resources.appendingPathComponent("Bundles"), modules: modules).load(folder, anyFolder: true).get()
            let wrappfile = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
            var conditions = BuildConditions.thisMac
            conditions.choices = choices
            return try BuildPlanner(bundle: loaded, wrappfile: wrappfile, modules: modules).plan(edition: edition, conditions: conditions)
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
            let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules"), added: AddedModules.folder()).loadAll().get()
            let folder = bundleFolder(ofGame: slug, resources: resources)
            let loaded = try ProgramBundleLoader(root: resources.appendingPathComponent("Bundles"), modules: modules).load(folder, anyFolder: true).get()
            let plan = try plan(forGame: slug, edition: edition, in: bundle)
            let used = plan?.target?.modules ?? composition.modules.map(\.rawValue)
            // Each module's data files by hash, and its stages by what they
            // do as planned, which its default updates compare (`when-changed`).
            let refs = try used.compactMap { id -> WrappLock.ModuleRef? in
                guard let module = modules.first(where: { $0.manifest.id == id }) else { return nil }
                var files = try (module.manifest.data ?? []).reduce(into: [String: String]()) { files, name in
                    files[name] = try LayerKey.hash(file: module.file(name))
                }
                // An update stage plans only for an update, and isn't compared.
                for path in module.manifest.stages ?? [] {
                    let name = (path as NSString).lastPathComponent
                    if BuildPlanner.isBuiltFromInput(id, name, modules: modules) { continue }
                    let planned = try plan?.stages.first { $0.module == id && $0.name == "\(id)/\(name)" }
                        ?? BuildPlanner.moduleStage(id, name, constraint: nil, modules: modules)
                    files[path] = planned?.plannedTextHash
                }
                return WrappLock.ModuleRef(id: id, release: module.manifest.release, version: module.manifest.versions.first?.version,
                                           files: files.isEmpty ? nil : files, package: module.manifest.package()?.package.prepared)
            }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            // The volumes the plan's launch mounts; for an edition with no
            // plan, those its first planned edition's does, as every edition
            // of a program runs it the same way.
            let manifest = loaded.manifest
            let launch = try plan?.launch ?? manifest.editions.lazy.filter { $0.build?.target != nil }
                .compactMap { try? Self.plan(forGame: slug, edition: $0.id, in: bundle)?.launch }.first
            let rules = (manifest.volumes ?? [:]).sorted { $0.key < $1.key }.map { name, volume -> VolumeRule in
                switch volume.inUseWhen {
                case .patterns(let patterns): VolumeRule(name: name, patterns: patterns)
                case .never: VolumeRule(name: name, patterns: [])
                case .anyFile, nil: VolumeRule(name: name, patterns: nil)
                }
            }
            var lock = WrappLock(bundle: .init(id: manifest.id, version: manifest.version), edition: edition,
                                 source: source.rawValue, composition: composition, modules: refs, builtBy: version,
                                 formerBundleIDs: manifest.formerBundleIds, volumes: rules.isEmpty ? nil : rules,
                                 savesVolume: launch?.savesVolume, scummvmSettingsVolume: launch?.scummvmSettingsVolume)
            lock.launch = plan?.launch
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
            let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules"), added: AddedModules.folder()).loadAll().get()
            let folder = bundleFolder(ofGame: slug, resources: resources)
            let loaded = try ProgramBundleLoader(root: resources.appendingPathComponent("Bundles"), modules: modules).load(folder, anyFolder: true).get()
            let wrappfile = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
            let planner = BuildPlanner(bundle: loaded, wrappfile: wrappfile, modules: modules)
            let edition = old.edition
            let updates = UpdatePlanner(manifest: loaded.manifest, modules: modules) { stage in
                try planner.plan(edition: edition, target: stage, conditions: .thisMac).target?.modules ?? []
            }
            let decision = try updates.plan(old: old, target: .init(
                bundleVersion: target.bundle.version, edition: target.edition, modules: target.modules, launch: target.launch,
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
            let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules"), added: AddedModules.folder()).loadAll().get()
            let folder = bundleFolder(ofGame: slug, resources: resources)
            let loaded = try ProgramBundleLoader(root: resources.appendingPathComponent("Bundles"), modules: modules).load(folder, anyFolder: true).get()
            let wrappfile = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
            var conditions = BuildConditions.thisMac
            conditions.updates = updates
            conditions.previous = previous
            return try BuildPlanner(bundle: loaded, wrappfile: wrappfile, modules: modules).plan(edition: edition, target: stage, conditions: conditions)
        } catch {
            throw WrappBuildError.buildRecipeProblem("\(slug) \(edition) \(stage): \(error)")
        }
    }

    /// What an update of the Nancy Drew game `slug`'s `edition` runs before
    /// its bundle's own update stages: the wine module's update stage when
    /// `wineUpdate` (and the game's cnc-ddraw settings when its build has
    /// them), else the old app's tree, given this Second Chance's engines
    /// for `modules` (`BuildPlanner.updatePlan`); with `wineMoved`, its
    /// prefix moved to this Wine (`WINE.PREFIX`, `wineboot -u`).
    static func updatePlan(forGame slug: String, edition: String, wineUpdate: Bool, wineMoved: Bool, modules ids: [String],
                           updates: [String], previous: [String: String], in bundle: Bundle = .main) throws -> BuildPlan {
        guard let resources = bundle.resourceURL else { throw WrappBuildError.buildRecipeProblem("no resources") }
        do {
            let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules"), added: AddedModules.folder()).loadAll().get()
            let folder = bundleFolder(ofGame: slug, resources: resources)
            let loaded = try ProgramBundleLoader(root: resources.appendingPathComponent("Bundles"), modules: modules).load(folder, anyFolder: true).get()
            let wrappfile = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
            let planner = BuildPlanner(bundle: loaded, wrappfile: wrappfile, modules: modules)
            // A DirectDraw game's cnc-ddraw settings, which old apps' shared
            // prefix had and the game's own build has now.
            let built = try planner.plan(edition: edition, conditions: .thisMac)
            let cncDdraw = wineUpdate && (built?.stages.flatMap(\.steps) ?? []).contains { $0.origin.hasPrefix("wine/functions/cnc-ddraw") }
            var conditions = BuildConditions.thisMac
            conditions.updates = updates
            conditions.previous = previous
            return try planner.updatePlan(moduleStage: wineUpdate ? ("wine", "update") : nil, engines: planner.engineModules(ids),
                                          then: (wineMoved ? ["WINE.PREFIX"] : []) + (cncDdraw ? ["DO wine.cnc-ddraw"] : []),
                                          edition: edition, conditions: conditions)
        } catch {
            throw WrappBuildError.buildRecipeProblem("\(slug) \(edition) update: \(error)")
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
        let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules"), added: AddedModules.folder()).loadAll().get()
        let loader = try ProgramBundleLoader(root: resources.appendingPathComponent("Bundles"), modules: modules)
        return try GameInfoProvider.shared.allGames().flatMap { game -> [DownloadEdition] in
            let folder = ExtraBundles.folder(of: game.programID, shippedRoot: resources.appendingPathComponent("Bundles"))
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.yaml").path) else { return [] }
            let bundle = try loader.load(folder, anyFolder: true).get()
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
        guard let resources = bundle.resourceURL else { return nil }
        let file = bundleFolder(ofGame: slug, resources: resources).appendingPathComponent("assets/\(name)")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}
