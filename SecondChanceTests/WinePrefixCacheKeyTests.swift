//
//  WinePrefixCacheKeyTests.swift
//  SecondChanceTests
//
//  A cached Wine prefix is only reused by the engine that created it.

import Foundation
import Testing
@testable import SecondChance
@testable import SecondChanceKit
@testable import WineKit

@Suite("Wine prefix cache key")
struct WinePrefixCacheKeyTests {
    @Test("The key carries the engine's version, as a path-safe slug")
    func carriesEngine() {
        #expect(WineManager.prefixCacheKey(build: "dev", engineVersion: "wine sikarugir 10.0 (revision 8)\n")
                == "dev-wine-sikarugir-10-0-revision-8")
        #expect(WineManager.prefixCacheKey(build: "512", engineVersion: "WS12WineCX24.0.7")
                == "512-ws12winecx24-0-7")
    }

    @Test("A different engine gets a different key, even in a Debug build")
    func engineChangesKey() {
        let wine9 = WineManager.prefixCacheKey(build: "dev", engineVersion: "wine cx 24.0.7")
        let wine10 = WineManager.prefixCacheKey(build: "dev", engineVersion: "wine sikarugir 10.0 (revision 8)")
        #expect(wine9 != wine10)
    }

    @Test("Without an engine version the key is the build alone", arguments: [nil, "", " ()\n"])
    func noEngine(version: String?) {
        #expect(WineManager.prefixCacheKey(build: "dev", engineVersion: version) == "dev")
    }

    @Test("Caching leaves another process's copy in progress alone, but not an old one")
    func otherCopies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prefix-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let incoming = dir.appendingPathComponent(".incoming-\(UUID().uuidString)")
        let cached = dir.appendingPathComponent("dev-other-engine")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)

        #expect(WineManager.isAnotherCopyInProgress(incoming))
        #expect(!WineManager.isAnotherCopyInProgress(incoming, now: Date().addingTimeInterval(2 * 3600)))
        #expect(!WineManager.isAnotherCopyInProgress(cached))
    }
}
