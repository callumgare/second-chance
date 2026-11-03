//
//  UpdatePlanner.swift
//  WrappBuilder
//
//  Which of a bundle's and its modules' updates bring an old wrapp up to
//  this build, worked out from the old wrapp's lock before anything runs.

import Foundation
import WrappFormat
import WrappModules

/// Works out how an old wrapp is brought up to what this build makes:
/// the updates that apply, in order, each from where the last left the
/// program (docs/wrapp-build.md#updating-a-wrapp), or that it must be built
/// afresh from its source. Reads only the manifest, the modules and the old
/// wrapp's lock, so whether an update needs the disc is known before it
/// starts.
public nonisolated struct UpdatePlanner {
    let manifest: Manifest
    let modules: [String: ModuleFolder]
    /// The modules a stage has, its `USE`s and `FROM`'s, by stage name.
    let stageModules: (String) throws -> [String]

    /// What this build makes: the bundle's version, and each module as it
    /// would record it in the lock.
    public struct Target: Sendable, Equatable {
        public var bundleVersion: Int
        public var edition: String
        public var modules: [WrappLock.ModuleRef]
        /// How this build's wrapps start their program; nil for an edition
        /// with no plan.
        public var launch: RecordedLaunch?
        /// The launcher's revision this build's wrapps carry.
        public var launcher: String?

        public init(bundleVersion: Int, edition: String, modules: [WrappLock.ModuleRef], launch: RecordedLaunch?,
                    launcher: String? = nil) {
            self.bundleVersion = bundleVersion
            self.edition = edition
            self.modules = modules
            self.launch = launch
            self.launcher = launcher
        }
    }

    /// One thing an update runs, in order.
    public enum Step: Sendable, Equatable {
        /// A Wrappfile stage, for each update that builds it (several can
        /// share one, which runs once).
        case stage(String, updates: [String])
        /// A module's default update its own Swift runs (`wine-prefix`).
        case module(String, update: String)
    }

    /// The updates that apply, and what they run.
    public struct Chain: Sendable, Equatable {
        /// Each update that applies, by id, in the order they run: what
        /// `IF updates has <id>` reads.
        public var applied: [String]
        public var steps: [Step]
        /// What the old wrapp recorded, as `previous.*` conditions read it.
        public var previous: [String: String]
        /// The runtime modules whose version moves with no update of their
        /// own: `wine` from `10.0_6` to `10.0_8` moves the prefix
        /// (`wineboot -u`).
        public var moves: [Move]

        public struct Move: Sendable, Equatable {
            public let module: String
            public let from: String
            public let to: String
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Bring the old wrapp forward: no disc needed unless a step uses it.
        case update(Chain)
        /// Build afresh from the source, saying why, for the log and the
        /// person.
        case freshBuild(String)
        /// Nothing to do: no update applies, and the wrapp already has this
        /// build's launcher and engines.
        case upToDate
    }

    /// Why the old wrapp's program isn't where this build's launch has it,
    /// so it's built afresh; nil when it is. An old lock with no launch says
    /// its game's folder (`args["install-dir"]`). A ScummVM game's data,
    /// which old wrapps kept in their prefix, the update moves into the app
    /// (`UpdateWrappBuilder`), so that isn't a move to build afresh for.
    static func programMoved(old: WrappLock, target: Target) -> String? {
        guard let new = target.launch?.program else { return nil }
        if old.composition.launcher == .scummvm, target.launch?.launcher() == .scummvm { return nil }
        if let program = old.launch?.program {
            return program == new ? nil : "its program is \(program), and this bundle's is \(new)"
        }
        guard let folder = old.args?["install-dir"] else { return nil }
        return new.hasPrefix("wine:" + folder + "/") ? nil : "its game is in \(folder), and this bundle's program is \(new)"
    }

    public init(manifest: Manifest, modules: [ModuleFolder], stageModules: @escaping (String) throws -> [String]) {
        self.manifest = manifest
        self.modules = Dictionary(modules.map { ($0.manifest.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.stageModules = stageModules
    }

    /// The modules that carry something of the build into the wrapp, whose
    /// version must reach this build's: their files are in it. A module
    /// that only does its work while building (the installer, nancy-drew's
    /// data) changes an old wrapp only through an update.
    static let carried: Set<String> = ["wine", "steam"]

    /// How to bring the wrapp `old` locks up to `target`.
    public func plan(old: WrappLock, target: Target) throws -> Decision {
        guard old.bundle.id == manifest.id else {
            return .freshBuild("it is another program's app (\(old.bundle.id))")
        }
        guard old.edition == target.edition, manifest.editions.contains(where: { $0.id == old.edition }) else {
            return .freshBuild("it was built from the \(old.edition) edition, not \(target.edition)")
        }
        if let moved = Self.programMoved(old: old, target: target) {
            return .freshBuild(moved)
        }

        var state = State(bundle: old.bundle.version, modules: Dictionary(old.modules.map { ($0.id, $0) }, uniquingKeysWith: { $1 }))
        let wanted = Dictionary(target.modules.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        var chain = Chain(applied: [], steps: [], previous: Self.previous(of: old), moves: [])
        // Modules an applied stage's `from` names: its author wrote it for
        // that version, so the move to this build's is theirs, across a
        // major version too (`from: { wine: "9" }`).
        var covered: Set<String> = []

        for candidate in candidates(target: target) {
            let update = candidate.update
            guard !chain.applied.contains(update.id) else { continue }
            if let owner = candidate.module {
                guard let want = wanted[owner], state.isBehind(owner, want) else { continue }
                if let files = update.whenChanged {
                    let old = state.modules[owner]?.files ?? [:]
                    guard files.contains(where: { old[$0] == nil || old[$0] != want.files?[$0] }) else { continue }
                }
            }
            guard state.meets(update.from) else { continue }
            if update.freshBuild == true {
                return .freshBuild("the \(update.id) update builds it afresh")
            }
            chain.applied.append(update.id)
            if update.build != nil || candidate.module == nil { covered.formUnion(update.from.map { Array($0.modules.keys) } ?? []) }

            if let owner = candidate.module, update.build == nil {
                // A module's own: its Swift brings its part up to this build.
                chain.steps.append(.module(owner, update: update.id))
                if let want = wanted[owner] { state.modules[owner] = want }
                continue
            }
            guard let stage = update.build?.target ?? editionTarget(target.edition) else {
                return .freshBuild("the \(update.id) update builds the \(target.edition) edition, which names no stage")
            }
            if let index = chain.steps.firstIndex(where: { if case .stage(stage, _) = $0 { true } else { false } }),
               case .stage(_, let ids) = chain.steps[index] {
                chain.steps[index] = .stage(stage, updates: ids + [update.id])
            } else {
                chain.steps.append(.stage(stage, updates: [update.id]))
            }
            if update.build == nil {
                // The edition's own target: exactly what this bundle builds,
                // so nothing after it applies.
                state.bundle = target.bundleVersion
                state.modules.merge(wanted) { $1 }
                break
            }
            for module in try stageModules(stage) {
                guard var want = wanted[module] else { continue }
                if let stop = update.to?.modules[module]?.version { want.version = stop }
                state.modules[module] = want
            }
            if let bundle = update.to?.bundle?.version.flatMap(Int.init) { state.bundle = bundle }
        }

        // Every module that carries files into the wrapp must reach this
        // build's version by a move that is known to work, within a major
        // version, made as the old wrapp's files are taken: whatever runs
        // after needs this build's Wine. (`to` stops a module short only for
        // the `from` of the updates after it.)
        let oldModules = Dictionary(old.modules.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for (id, want) in wanted.sorted(by: { $0.key < $1.key }) where Self.carried.contains(id) {
            let have = oldModules[id]?.version
            guard have != want.version else { continue }
            guard let have, let to = want.version else {
                return .freshBuild("it doesn't say which \(id) it was built with")
            }
            guard id == "wine", Self.major(have) == Self.major(to) || covered.contains(id) else {
                return .freshBuild("its \(id) \(have) can't be moved to \(to) without building it afresh")
            }
            chain.moves.append(.init(module: id, from: have, to: to))
        }

        // Every wrapp has a launcher, which an update always brings: with no
        // update to apply and this build's launcher and engines already in
        // it, there is nothing to bring.
        let sameEngines = target.modules.allSatisfy { want in want.package == nil || oldModules[want.id]?.package == want.package }
        if chain.applied.isEmpty, chain.moves.isEmpty, sameEngines, let launcher = target.launcher, old.launcher == launcher {
            return .upToDate
        }
        return .update(chain)
    }

    // MARK: - The program as it is at each point

    struct State {
        var bundle: Int
        var modules: [String: WrappLock.ModuleRef]

        /// Whether the program's copy of `module` isn't the build's.
        func isBehind(_ module: String, _ want: WrappLock.ModuleRef) -> Bool {
            guard let have = modules[module] else { return true }
            return have.version != want.version || have.release != want.release || have.files != want.files
        }

        func meets(_ requirements: Update.Requirements?) -> Bool {
            guard let requirements else { return true }
            if let bundle = requirements.bundle, !bundle.holds(version: String(self.bundle), release: nil) { return false }
            for (id, requirement) in requirements.modules {
                guard let have = modules[id] else { return false }
                if !requirement.holds(version: have.version, release: have.release) { return false }
            }
            return true
        }
    }

    struct Candidate {
        let update: Update
        /// The module whose default update it is; nil for the bundle's own.
        let module: String?
    }

    /// The bundle's updates, then each module's defaults in the order the
    /// target first has them. A bundle entry with only an id names a
    /// module's default, to run it earlier; one with more replaces it.
    func candidates(target: Target) -> [Candidate] {
        var defaults: [String: Candidate] = [:]
        var order: [String] = []
        for ref in target.modules {
            for update in modules[ref.id]?.manifest.updates ?? [] where defaults[update.id] == nil {
                defaults[update.id] = Candidate(update: update, module: ref.id)
                order.append(update.id)
            }
        }
        var list: [Candidate] = []
        var listed: Set<String> = []
        for update in manifest.updates ?? [] {
            listed.insert(update.id)
            let onlyID = update.from == nil && update.to == nil && update.build == nil
                && update.freshBuild == nil && update.whenChanged == nil
            if onlyID, let module = defaults[update.id] {
                list.append(module)
            } else {
                list.append(Candidate(update: update, module: nil))
            }
        }
        list += order.filter { !listed.contains($0) }.compactMap { defaults[$0] }
        return list
    }

    func editionTarget(_ edition: String) -> String? {
        manifest.editions.first { $0.id == edition }?.build?.target
    }

    /// `previous.bundle`, `previous.wine`, `previous.edition`: what the old
    /// wrapp's lock records, for conditions.
    static func previous(of lock: WrappLock) -> [String: String] {
        var values = ["bundle": String(lock.bundle.version), "edition": lock.edition]
        for module in lock.modules {
            if let version = module.version { values[module.id] = version }
        }
        return values
    }

    /// `10` of `10.0_8`.
    static func major(_ version: String) -> Substring {
        version.prefix { $0.isNumber }
    }
}
