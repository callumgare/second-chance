//
//  GStreamerCacheTests.swift
//  WineKitTests
//
//  Each copy of Wine's GStreamer has a plugin cache of its own.

import Foundation
import Logging
import Testing
@testable import WineKit

@Suite("GStreamer cache")
struct GStreamerCacheTests {
    @Test func eachCopyOfGStreamerHasACacheOfItsOwn() {
        let first = Wine(wrapp: URL(fileURLWithPath: "/tmp/Iji.app"))
        let second = Wine(wrapp: URL(fileURLWithPath: "/tmp/Icy Tower.app"))
        let again = Wine(wrapp: URL(fileURLWithPath: "/tmp/Iji.app"))
        #expect(first.gstreamerRegistry != second.gstreamerRegistry)
        #expect(first.gstreamerRegistry == again.gstreamerRegistry)
        #expect(first.gstreamerRegistry.path.contains("SecondChance/gstreamer/registry-"))
        #expect(first.gstreamerRegistry.lastPathComponent.hasSuffix(".x86_64.bin"))
    }

    @Test func wineIsGivenThatCache() {
        let wine = Wine(wrapp: URL(fileURLWithPath: "/tmp/Iji.app"))
        #expect(wine.variables["GST_REGISTRY"] == wine.gstreamerRegistry.path)
    }

    @Test func theTemplatesGStreamerUnlessWineBringsItsOwn() throws {
        let wrapp = FileManager.default.temporaryDirectory.appendingPathComponent("gst-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: wrapp) }
        let wine = Wine(wrapp: wrapp)
        #expect(wine.gstreamerFramework.path.hasSuffix("Contents/Frameworks/GStreamer.framework"))
        // A WineHQ build's GStreamer, inside Wine's own lib folder.
        let own = wrapp.appendingPathComponent("Contents/SharedSupport/wine/lib/GStreamer.framework/Libraries/gstreamer-1.0")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        #expect(Wine(wrapp: wrapp).gstreamerFramework.path.hasSuffix("SharedSupport/wine/lib/GStreamer.framework"))
    }

    @Test func aCacheAlreadyThereIsLeftAlone() async throws {
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent("gst-caches-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: caches) }
        let registry = Wine.gstreamerRegistry(for: URL(fileURLWithPath: "/tmp/x/GStreamer.framework"), caches: caches)
        #expect(registry.path.hasPrefix(caches.path))
        try FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cached".utf8).write(to: registry)
        // A wrapp with no GStreamer at all: warming must neither run anything
        // nor touch a cache that's there.
        let wine = Wine(wrapp: URL(fileURLWithPath: "/tmp/no-such-wrapp.app"))
        await wine.warmGStreamerCache(logger: Logger(label: "test"))
        #expect(try Data(contentsOf: registry) == Data("cached".utf8))
    }
}
