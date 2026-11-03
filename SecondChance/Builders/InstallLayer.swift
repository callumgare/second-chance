//
//  InstallLayer.swift
//  SecondChance
//
//  The installed game as a cached layer: a build of the same edition from the
//  same disc, with the same bundle and modules, clones it instead of copying
//  the disc and running the installer again.

import Foundation
import Logging
import Synchronization
import GameCatalog
import SecondChanceKit
import WrappBuilder

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.InstallLayer")

/// What a build caches as layers (docs/wrapp-build.md#the-layer-cache):
/// `SECOND_CHANCE_LAYER_CACHE` (`sc … --debug layer-cache=<policy>`), else
/// everything, but only the prefix under test, so an integration run
/// installs every game for real.
nonisolated enum LayerCachePolicy: String, Sendable {
    /// Nothing: every build makes its own prefix and installs.
    case off
    /// The new Wine prefix alone.
    case prefix
    /// The prefix and the installed game.
    case all

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> LayerCachePolicy {
        if let value = environment["SECOND_CHANCE_LAYER_CACHE"], let policy = LayerCachePolicy(rawValue: value) {
            return policy
        }
        return TestHost.isRunning ? .prefix : .all
    }
}

/// The game installed into the prefix — its discs copied, its installer
/// run, its patches applied and its settings made — as a layer on the
/// prefix's. On a hit the build restores the layer's prefix and publishes
/// again what the install published, so the progress screen and the
/// integration tests see the same `installerResolved`, `gameExeDetected`
/// and `patchApplied` whether it was installed or restored.
struct InstallLayer {
    let store: LayerStore
    let bus: EventBus<AppEvent>

    /// What an install gives the rest of the build.
    nonisolated struct Installed: Codable, Sendable {
        var gameExePath: String
        var installerDir: String
        var configuredINI: Bool
    }

    /// The events an install published that the build gives again on a hit.
    nonisolated enum Recorded: Codable, Sendable, Equatable {
        case disksResolved(disk2: URL?)
        case engineRouted
        case installerResolved(exePath: String, type: String)
        case gameExeDetected(path: String)
        case patchApplied(id: String)
        case patchFailed(id: String, message: String)
    }

    nonisolated struct Record: Codable, Sendable {
        var installed: Installed
        var events: [Recorded]
    }

    /// Raised whenever the Swift that installs a game (the builders' plan
    /// runs, `GameInstallerRunner`) changes what an install makes: the one
    /// input of the key no file holds.
    nonisolated static let codeRevision = 1

    /// The key of `plan`'s install, on the prefix the wrapp has now: the
    /// plan's steps, the bundle's assets they read, every module the plan
    /// uses (its release and its files), and `inputs`, what this source
    /// adds (a disc's listing).
    nonisolated static func key(
        slot: String, plan: BuildPlan, wrappPath: URL, inputs: [LayerKey.Input]
    ) throws -> LayerKey {
        guard let resources = Bundle.main.resourceURL else { throw WrappBuildError.templateDamaged("Second Chance has no resources") }
        let steps = plan.stages.flatMap(\.steps)
        var keyed: [LayerKey.Input] = [.init("edition", plan.edition),
                                       .init("plan", steps.map(\.description).joined(separator: "\n"))]
        // The bundle's and modules' files the steps read, by their full form
        // (`bundle:assets/disc.iss`), so where Second Chance is installed
        // doesn't change the key.
        for (name, file) in plan.files.sorted(by: { $0.key < $1.key }) {
            keyed.append(.init("file \(name)", try LayerKey.hash(file: file)))
        }
        let modules = resources.appendingPathComponent("Modules")
        let loader = try ModuleLoader(root: modules)
        for id in Set(plan.stages.flatMap(\.modules)).sorted() {
            guard let module = loader.module(id) else { continue }
            keyed.append(.init("\(id) release", String(module.manifest.release)))
            keyed.append(.init("\(id) files", try LayerKey.hash(folder: module.folder)))
        }
        keyed.append(.init("install code revision", String(codeRevision)))
        keyed.append(.init("arch", BuildConditions.thisMac.arch))
        return LayerKey(slot: slot, parent: try WineManager.prefixLayerKey(for: wrappPath), inputs: keyed + inputs)
    }

    /// The install for `key`: restored from the store, or made by `install`
    /// and kept. Nil `key` installs without the store. An install with a
    /// patch that failed isn't kept, so the next build tries the patch
    /// again; nor, under a policy short of `all`, is any.
    func run(
        key: LayerKey?, wrappPath: URL, gameInfo: GameInfo, disk1: URL?, install: () async throws -> Installed
    ) async throws -> Installed {
        guard let key, LayerCachePolicy.current() == .all else { return try await install() }
        if let why = store.explain(key) {
            logger.notice("No cached install to use (\(why)): installing")
        }
        let prefix = WrappLayout(app: wrappPath).prefix
        var made: Installed?
        do {
            let (layer, built) = try await store.layer(for: key) { content in
                let recorder = Recorder()
                let token = await bus.subscribe { event in recorder.record(event) }
                let installed: Installed
                do {
                    installed = try await install()
                } catch {
                    await bus.unsubscribe(token)
                    throw error
                }
                await bus.unsubscribe(token)
                made = installed
                let events = recorder.events
                if events.contains(where: { if case .patchFailed = $0 { true } else { false } }) {
                    throw NotKept(reason: "a patch failed, so the next build tries it again")
                }
                logger.notice("Caching the install \(key.hash.prefix(12))...")
                try await Blocking.run {
                    if clonefile(prefix.path, content.path, 0) != 0 {
                        logger.notice("Copying the install into the cache, as it's on another volume")
                        try FileManager.default.copyItem(at: prefix, to: content)
                    }
                }
                return try JSONEncoder().encode(Record(installed: installed, events: events))
            }
            if built, let made {
                logger.notice("✓ Cached the install \(key.hash.prefix(12))")
                return made
            }
            guard let data = layer.events else { throw NotKept(reason: "the cached install has no record") }
            let record = try JSONDecoder().decode(Record.self, from: data)
            logger.notice("✓ Using the cached install \(key.hash.prefix(12))")
            await bus.publishWrappBuild(.progress(.installingGame(substep: nil)))
            let restored = try await Blocking.run { () throws -> LayerStore.Restored in
                try? FileManager.default.removeItem(at: prefix)
                return try store.restore(layer, to: prefix)
            }
            if restored == .copied {
                logger.notice("Copied the cached install, as the cache is on another volume from the build")
            }
            for event in record.events {
                await bus.publishWrappBuild(event.event(disk1: disk1, gameInfo: gameInfo))
            }
            return record.installed
        } catch {
            // Caching is only a saving for the next build: one that installed
            // the game carries on with it.
            guard let made else { throw error }
            if let notKept = error as? NotKept {
                logger.notice("Not caching this install: \(notKept.reason)")
            } else {
                logger.warning("Couldn't cache the install, so the next build installs again: \(error.localizedDescription)")
            }
            return made
        }
    }

    private struct NotKept: Error {
        let reason: String
    }

    /// What the install publishes, kept as it's published.
    private nonisolated final class Recorder: Sendable {
        private let recorded = Mutex<[Recorded]>([])

        var events: [Recorded] { recorded.withLock { $0 } }

        func record(_ event: AppEvent) {
            guard case .wrappBuild(let build) = event, let kept = Recorded(build) else { return }
            recorded.withLock { $0.append(kept) }
        }
    }
}

nonisolated extension InstallLayer.Recorded {
    init?(_ event: WrappBuildEvent) {
        switch event {
        case .disksResolved(_, let disk2): self = .disksResolved(disk2: disk2)
        case .engineRouted: self = .engineRouted
        case .installerResolved(let exePath, let type): self = .installerResolved(exePath: exePath, type: "\(type)")
        case .gameExeDetected(let path, _): self = .gameExeDetected(path: path)
        case .patchApplied(let id): self = .patchApplied(id: id)
        case .patchFailed(let id, let message): self = .patchFailed(id: id, message: message)
        default: return nil
        }
    }

    /// The event again, for this build: its own disc, and the game it
    /// detected.
    func event(disk1: URL?, gameInfo: GameInfo) -> WrappBuildEvent {
        switch self {
        case .disksResolved(let disk2): .disksResolved(disk1: disk1 ?? URL(fileURLWithPath: "/"), disk2: disk2)
        case .engineRouted: .engineRouted(composition: gameInfo.composition, gameInfo: gameInfo)
        case .installerResolved(let exePath, let type): .installerResolved(exePath: exePath, type: InstallerType(recorded: type))
        case .gameExeDetected(let path): .gameExeDetected(path: path, gameInfo: gameInfo)
        case .patchApplied(let id): .patchApplied(id: id)
        case .patchFailed(let id, let message): .patchFailed(id: id, message: message)
        }
    }
}

nonisolated extension InstallerType {
    init(recorded: String) {
        self = [InstallerType.msi, .installShield, .innoSetup].first { "\($0)" == recorded } ?? .unknown
    }
}
