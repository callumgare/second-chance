//
//  PrefixLayerKeyTests.swift
//  WrappBuilderTests
//
//  A cached prefix is reused only by a build that would make the same one.

import Foundation
import Testing
@testable import WrappBuilder

@Suite("Wine prefix layer key")
struct PrefixLayerKeyTests {
    /// The repo's modules, copied so a test can change one.
    func copiedModules() throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("prefix-key-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: modulesRoot, to: copy)
        return copy
    }

    @Test func theStageIsTodaysInOrder() throws {
        let stage = try WineBuild.prefixStage(modules: modulesRoot)
        #expect(stage.steps.map(\.instruction) == ["ENGINE", "HELPERS", "PREFIX", "DRIVES", "REGISTRY", "WINETRICKS"])
        // What the progress screen says for each, before the step it's for.
        #expect(stage.emits.map(\.text) == ["second-chance.substep.display", "second-chance.substep.disc"])
        #expect(stage.emits.map { stage.steps[$0.before].instruction } == ["REGISTRY", "WINETRICKS"])
    }

    @Test func theKeyFollowsTheEngineTheStageAndWinetricks() throws {
        let modules = try copiedModules()
        defer { try? FileManager.default.removeItem(at: modules) }
        let winetricks = modules.appendingPathComponent("winetricks")
        try Data("#!/bin/sh\n".utf8).write(to: winetricks)
        func key(_ engine: String = "wine sikarugir 10.0 (revision 8)\n") throws -> LayerKey {
            try WineBuild.prefixLayerKey(engineVersion: engine, stage: WineBuild.prefixStage(modules: modules), winetricks: winetricks)
        }
        let original = try key()
        #expect(try key() == original)
        #expect(original.inputs.first == LayerKey.Input("wine engine", "wine sikarugir 10.0 (revision 8)"))
        #expect(try key("wine cx 24.0.7").hash != original.hash)

        // A change to the stage's steps is a new prefix, with nothing to
        // clear; a comment changes no step.
        let stage = modules.appendingPathComponent("wine/stages/prefix")
        let text = try String(contentsOf: stage, encoding: .utf8)
        try (text + "\n# changed\n").write(to: stage, atomically: true, encoding: .utf8)
        #expect(try key() == original)
        try (text + "\nWINE.WINETRICKS corefonts\n").write(to: stage, atomically: true, encoding: .utf8)
        let changedStage = try key()
        #expect(changedStage.differences(from: original) == ["`wine prefix stage` changed"])

        try Data("#!/bin/sh\n# newer\n".utf8).write(to: winetricks)
        #expect(try key().differences(from: changedStage) == ["`winetricks` changed"])
    }
}
