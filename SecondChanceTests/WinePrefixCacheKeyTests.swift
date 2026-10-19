//
//  WinePrefixCacheKeyTests.swift
//  SecondChanceTests
//
//  A cached Wine prefix is only reused by the engine that created it.

import Testing
@testable import SecondChance

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
}
