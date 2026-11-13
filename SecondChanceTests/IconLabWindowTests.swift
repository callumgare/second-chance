//
//  IconLabWindowTests.swift
//  SecondChanceTests
//
//  The Icon Lab window's web view, offscreen: the page loads through the
//  iconlab:// scheme handler and its API answers, over a scratch data
//  folder. And moving the standalone lab's data in.

import Foundation
import Testing
import IconLabAPI
import IconLabKit
import WebKit
@testable import SecondChance

@MainActor
@Suite struct IconLabWindowTests {
    /// A fresh folder, removed when `body` is done.
    func withScratch(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iconlab-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    /// Polls `check` until it's true, for up to `seconds`.
    func eventually(_ seconds: Double = 20, _ check: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    // A backstop: the page's load is waited on, not timed, so a load that never ends ends here.
    @Test(.timeLimit(.minutes(2))) func thePageLoadsAndItsAPIAnswers() async throws {
        try await withScratch { dir in
            let host = IconLabHost(paths: IconLabPaths(data: dir.appendingPathComponent("data")))
            let page = IconLabPage(api: host.api)
            defer { page.close() }
            let web = page.webView
            let loaded = await page.waitUntilLoaded()
            try #require(loaded, "the page loaded")
            // the page's own script ran: it defines the host's event function as it loads
            let booted = await eventually {
                (try? await web.evaluateJavaScript("typeof window.iconLabHost?.event") as? String) == "function"
            }
            #expect(booted)
            let answer = try await web.callAsyncJavaScript(
                "const r = await fetch('/api/programs'); return [r.status, await r.text()]",
                arguments: [:], contentWorld: .page) as? [Any]
            #expect(answer?.first as? Int == 200)
            #expect(answer?.last as? String == "[]")
            let missing = try await web.callAsyncJavaScript(
                "const r = await fetch('/api/programs/nothing', {method: 'PATCH', body: '{}'}); return r.status",
                arguments: [:], contentWorld: .page) as? Int
            #expect(missing == 404)
        }
    }

    @Test(.timeLimit(.minutes(2))) func eventsReachThePage() async throws {
        try await withScratch { dir in
            let host = IconLabHost(paths: IconLabPaths(data: dir.appendingPathComponent("data")))
            let page = IconLabPage(api: host.api)
            defer { page.close() }
            let web = page.webView
            let loaded = await page.waitUntilLoaded()
            try #require(loaded, "the page loaded")
            _ = try await web.callAsyncJavaScript(
                "window.__seen = []; const e = window.iconLabHost.event; window.iconLabHost.event = (j) => { window.__seen.push(j); e(j) }",
                arguments: [:], contentWorld: .page)
            // the events task starts with the page; give it a moment to be listening, then send until one lands
            let arrived = await eventually {
                await host.api.lab.jobs.broadcast(["type": "test", "text": "quote \" and </script>"])
                let text = try? await web.callAsyncJavaScript(
                    "return window.__seen.length ? JSON.parse(window.__seen[0]).text : null", arguments: [:], contentWorld: .page) as? String
                return text == "quote \" and </script>"
            }
            #expect(arrived)
        }
    }

    @Test func theHostGivesSecondChancesProgramsAndItsBundles() throws {
        let known = IconLabPaths.knownPrograms()
        #expect(known.contains { $0.id == "freeware/skifree" && $0.title == "SkiFree" })
        #expect(Set(known.map(\.id)).count == known.count)
        let paths = IconLabPaths.current(environment: ["SECOND_CHANCE_ICON_LAB_BUNDLES": "/nonexistent/Bundles",
                                                        "SECOND_CHANCE_ICON_LAB_DATA": "/nonexistent/data"])
        #expect(paths.host.bundles?.path == "/nonexistent/Bundles")
        #expect(paths.data.path == "/nonexistent/data")
        #expect(paths.host.knownPrograms.count == known.count)
    }

    @Test func oldDataIsOfferedOnlyIntoAnEmptyFolder() async throws {
        try await withScratch { dir in
            let old = dir.appendingPathComponent("old"), new = dir.appendingPathComponent("new")
            #expect(IconLabMigration.offer(from: old, to: new) == nil)   // nothing to move
            try FileManager.default.createDirectory(at: old.appendingPathComponent("programs/skifree"), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: old.appendingPathComponent("programs/skifree/program.json"))
            #expect(IconLabMigration.offer(from: old, to: new) == old)
            // empty folders, as the engine makes, still count as empty
            try FileManager.default.createDirectory(at: new.appendingPathComponent("cache"), withIntermediateDirectories: true)
            #expect(IconLabMigration.offer(from: old, to: new) == old)
            try Data("x".utf8).write(to: new.appendingPathComponent("cache/file"))
            #expect(IconLabMigration.offer(from: old, to: new) == nil)
            #expect(throws: (any Error).self) { try IconLabMigration.move(old, to: new) }
            #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("programs/skifree/program.json").path))
        }
    }

    @Test func movingBringsEverythingAcross() async throws {
        try await withScratch { dir in
            let old = dir.appendingPathComponent("old"), new = dir.appendingPathComponent("support/Icon Lab")
            try FileManager.default.createDirectory(at: old.appendingPathComponent("programs/skifree"), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: old.appendingPathComponent("programs/skifree/program.json"))
            try FileManager.default.createDirectory(at: new.appendingPathComponent("programs"), withIntermediateDirectories: true)
            try IconLabMigration.move(old, to: new)
            #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("programs/skifree/program.json").path))
            #expect(!FileManager.default.fileExists(atPath: old.path))
        }
    }
}
