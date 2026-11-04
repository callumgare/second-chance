//
//  Mounts.swift
//  WrappBuilder
//
//  A step's mounts: put where each target says before it, taken away after.

import Foundation
import Logging
import ProcessKit

/// The mount realisers, one per core type: `bind` (a file of the bundle's
/// or a module's) and `fetch` (a download, by its hash), each put at its
/// `target` before the step as a clone, so the step can't change the
/// original, and taken away after; and `store`, its target a link to the
/// store's folder while the step runs, so what the step changes there it
/// changes in the store, then gone, or with `snapshot` a clone of what the
/// store holds left in the tree.
nonisolated enum Mounts {
    /// What a step's mounts put in its tree, for `remove`: each target,
    /// and for a snapshot the store it's cloned from.
    struct Placed: Sendable {
        var items: [URL] = []
        var snapshots: [URL: URL] = [:]
    }

    static func place(_ mounts: [String], for step: PlannedStep, in context: LocalStepContext) async throws -> Placed {
        var placed = Placed()
        do {
            for mount in mounts {
                let fields = PlannedStep.fields(ofMount: mount)
                guard let targetPath = fields["target"] else {
                    throw StepFailure.recipe("\(step.origin): a mount names its target: \(mount)")
                }
                let target = try context.location(targetPath)
                if fields["type"] == "store" {
                    guard let name = fields["source"] else {
                        throw StepFailure.recipe("\(step.origin): a store mount names its store: \(mount)")
                    }
                    // A build step never changes a kept store; a module's executor may
                    // its own, given as an option rather than a mount.
                    let folder = try await context.use(store: name) { _ in false }
                    try await Blocking.run {
                        let files = FileManager.default
                        if files.fileExists(atPath: target.path) || (try? files.destinationOfSymbolicLink(atPath: target.path)) != nil {
                            throw StepFailure.failed("\(step.origin): a mount's target is there already: \(targetPath)")
                        }
                        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try files.createSymbolicLink(at: target, withDestinationURL: folder)
                    }
                    placed.items.append(target)
                    if fields["snapshot"] != nil { placed.snapshots[target] = folder }
                    continue
                }
                let source: URL
                let work: URL?
                switch fields["type"] {
                case "bind":
                    guard let name = fields["source"], let file = context.file(name) else {
                        throw StepFailure.recipe("\(step.origin): the plan has no file \(fields["source"] ?? "") to mount")
                    }
                    (source, work) = (file, nil)
                case "fetch":
                    guard let url = fields["url"].flatMap(URL.init(string:)), let sha256 = fields["sha256"] else {
                        throw StepFailure.recipe("\(step.origin): a fetch mount names its url and sha256")
                    }
                    let download = try await context.fetch(url: url, sha256: sha256)
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fetch-\(UUID().uuidString)")
                    source = try await Archive.member(of: download, named: fields["member"], unpack: fields["unpack"], in: folder,
                                                      called: url.lastPathComponent, origin: step.origin)
                    work = folder
                default:
                    throw StepFailure.recipe("\(step.origin): this build can't make a \(fields["type"] ?? "") mount")
                }
                defer { if let work { try? FileManager.default.removeItem(at: work) } }
                try await Blocking.run {
                    let files = FileManager.default
                    if files.fileExists(atPath: target.path) {
                        throw StepFailure.failed("\(step.origin): a mount's target is there already: \(targetPath)")
                    }
                    try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileCopy.clone(source, to: target)
                }
                placed.items.append(target)
            }
        } catch {
            await remove(placed, log: context.log)
            throw error
        }
        return placed
    }

    /// Take away what `place` put in the tree, last first; a failure is
    /// only logged.
    static func remove(_ placed: Placed, log: Logger) async {
        for item in placed.items.reversed() {
            await Blocking.run {
                do {
                    try FileManager.default.removeItem(at: item)
                    // A snapshot leaves what the store holds now in the tree.
                    if let store = placed.snapshots[item] { try FileCopy.clone(store, to: item) }
                } catch {
                    log.warning("Couldn't take the mount \(item.lastPathComponent) away: \(error.localizedDescription)")
                }
            }
        }
    }
}
