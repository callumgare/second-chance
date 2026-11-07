//
//  WinePatches.swift
//  WineExecutor
//
//  WINE.PATCH <name>…: the wine module's patches to Wine's own DLLs, by
//  name, each made in a tree's own copy of Wine (cloned from the engine
//  store, replaced file by file, so the store is never touched). A patch is
//  the last resort: a newer Wine, then a winetricks verb, come first
//  (docs/modules.md#the-wine-modules-patches).

import Foundation
import WrappModuleKit

/// One patch to Wine's own code, as `WINE.PATCH` names it.
public nonisolated struct WinePatch: Sendable {
    /// Its name in a Wrappfile (`WINE.PATCH keep-thread-handles`).
    public let name: String
    /// Part of the step's key: raised whenever what the patch makes changes,
    /// so a layer an earlier one made isn't restored.
    public let revision: Int
    /// What it does, for the log once it's made.
    public let does: String
    /// Makes it in the tree's own Wine; true when it was already made.
    let apply: @Sendable (URL) throws -> Bool

    /// Every patch, by name.
    public static let all: [String: WinePatch] = Dictionary(uniqueKeysWithValues: [
        WinePatch(name: "keep-thread-handles", revision: KeepThreadHandles.revision,
                  does: "msvcrt.dll's _endthread keeps a thread's handle") {
            try KeepThreadHandles.apply(in: $0) == .alreadyPatched
        },
        WinePatch(name: "skip-synth-playout", revision: SkipSynthPlayout.revision,
                  does: "dmsynth.dll's sink stops without playing out its buffer") {
            try SkipSynthPlayout.apply(in: $0) == .alreadyPatched
        },
    ].map { ($0.name, $0) })

    /// The patches `names` names, or a recipe failure naming one that isn't.
    public static func named(_ names: [String], origin: String) throws -> [WinePatch] {
        guard !names.isEmpty else { throw StepFailure.recipe("\(origin): WINE.PATCH names the patches to make") }
        return try names.map { name in
            guard let patch = all[name] else {
                let known = all.keys.sorted().joined(separator: ", ")
                throw StepFailure.recipe("\(origin): WINE.PATCH has no patch \(name) (it has \(known))")
            }
            return patch
        }
    }

    init(name: String, revision: Int, does: String, apply: @escaping @Sendable (URL) throws -> Bool) {
        self.name = name
        self.revision = revision
        self.does = does
        self.apply = apply
    }
}
