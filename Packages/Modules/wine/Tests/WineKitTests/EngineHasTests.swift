//
//  EngineHasTests.swift
//  WineKitTests
//
//  What a Wine has (a module.yaml's `has:`, as a wrapp's lock records it),
//  and the variables it decides: msync's, and what the in-process helpers
//  are told (docs/modules.md#what-an-engine-has).

import Foundation
import Testing
@testable import WineKit
@testable import WrappFormat
import WrappModules

@Suite("What a Wine has")
struct EngineHasTests {
    let wrapp = URL(fileURLWithPath: "/nowhere/Game.app")

    @Test("A Wine whose features aren't known is asked for msync and tells the helpers nothing")
    func unknown() {
        let variables = Wine(wrapp: wrapp).variables
        #expect(variables["WINEMSYNC"] == "1")
        #expect(variables["WINE_ENGINE_HAS"] == nil)
    }

    @Test("A Wine known not to have msync isn't asked for it")
    func noMsync() {
        let variables = Wine(wrapp: wrapp, engineHas: []).variables
        #expect(variables["WINEMSYNC"] == nil)
        #expect(variables["WINEESYNC"] == nil)
        #expect(variables["WINE_ENGINE_HAS"] == "")
    }

    @Test("A Wine with msync is asked for it, and the helpers are told what it has, sorted")
    func withMsync() {
        let variables = Wine(wrapp: wrapp, engineHas: [Wine.Has.msync, Wine.Has.cocoaStartWait]).variables
        #expect(variables["WINEMSYNC"] == "1")
        #expect(variables["WINE_ENGINE_HAS"] == "cocoa-start-wait,msync")
    }

    @Test("A lock gives what its Wine has; one from before it was recorded, nothing")
    func lock() throws {
        let composition = Composition(launcher: .wine)
        var lock = WrappLock(bundle: .init(id: "nancy-drew/old-clock", version: 1), edition: "cd", source: "disk",
                             composition: composition,
                             modules: [.init(id: "wine", release: 34, version: "10.0_8", has: ["msync"])],
                             builtBy: "test")
        let layout = WrappLayout(app: FileManager.default.temporaryDirectory
            .appendingPathComponent("EngineHasTests-\(UUID().uuidString).app"))
        defer { try? FileManager.default.removeItem(at: layout.app) }
        try lock.write(to: layout)
        let read = try #require(try WrappLock(of: layout))
        #expect(read.has(module: "wine") == ["msync"])
        lock.modules = [.init(id: "wine", release: 33, version: "10.0_8")]
        #expect(lock.has(module: "wine") == nil)
        #expect(lock.has(module: "scummvm") == nil)
    }
}
