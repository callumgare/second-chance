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

    @Test func theKeyFollowsTheEngineTheSetUpAndWinetricks() throws {
        let modules = try copiedModules()
        defer { try? FileManager.default.removeItem(at: modules) }
        let winetricks = modules.appendingPathComponent("winetricks")
        try Data("#!/bin/sh\n".utf8).write(to: winetricks)
        func key() throws -> LayerKey {
            try WineBuild.prefixLayerKey(engineVersion: "wine sikarugir 10.0 (revision 8)\n", modules: modules, winetricks: winetricks)
        }
        let original = try key()
        #expect(try key() == original)
        #expect(original.inputs.first == LayerKey.Input("wine engine", "wine sikarugir 10.0 (revision 8)"))

        let otherEngine = try WineBuild.prefixLayerKey(engineVersion: "wine cx 24.0.7", modules: modules, winetricks: winetricks)
        #expect(otherEngine.hash != original.hash)

        // A change to the set-up is a new prefix, with nothing to clear.
        let setup = modules.appendingPathComponent("wine/prefix.yaml")
        try (String(contentsOf: setup, encoding: .utf8) + "\n# changed\n").write(to: setup, atomically: true, encoding: .utf8)
        let changedSetup = try key()
        #expect(changedSetup.hash != original.hash)
        #expect(changedSetup.differences(from: original) == ["`wine prefix.yaml` changed"])

        try Data("#!/bin/sh\n# newer\n".utf8).write(to: winetricks)
        #expect(try key().differences(from: changedSetup) == ["`winetricks` changed"])
    }
}
