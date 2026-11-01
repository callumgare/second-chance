//
//  WineNoDisplayTests.swift
//  SecondChanceTests
//
//  A Wine program that found no display fails, whatever its exit code.

import Foundation
import Testing
@testable import SecondChance
@testable import SecondChanceKit

@Suite("Wine programs without a display")
struct WineNoDisplayTests {
    @Test("Wine's nodrv_CreateWindow error fails the run even when the program exits 0")
    func noDisplayFails() async throws {
        let fake = try FakeWine(wine: """
            echo '0428:err:winediag:nodrv_CreateWindow Application tried to create a window, but no driver could be loaded.' >&2
            exit 0
            """)
        defer { fake.remove() }

        do {
            try await fake.wine.run(.program("AutoIt3.exe"))
            Issue.record("Expected WineError.noDisplay")
        } catch WineError.noDisplay {
            // Expected.
        } catch {
            Issue.record("Expected WineError.noDisplay, got \(error)")
        }
    }

    @Test("Other error lines leave a clean exit alone")
    func otherErrorsPass() async throws {
        let fake = try FakeWine(wine: #"echo '0080:err:environ:init_peb starting L"C:\\setup.exe" in experimental wow64 mode' >&2"#)
        defer { fake.remove() }

        try await fake.wine.run(.program("setup.exe"))
    }
}

@Suite("Lines that mean no display")
struct NoDisplaySignalTests {
    @Test("Both of Wine's no-display lines count, and nothing else", arguments: [
        ("015c:err:winediag:nodrv_CreateWindow Application tried to create a window, but no driver could be loaded.", true),
        ("015c:err:macdrv:macdrv_init Failed to start Cocoa app main loop", true),
        ("015c:err:winediag:nodrv_CreateWindow L\"The explorer process failed to start.\"", true),
        ("0130:err:vulkan:vulkan_init_once Failed to load libvulkan.1.dylib", false),
        ("second-chance-helper[CocoaStart] warning: the main thread took 7.2s to start Cocoa, past Wine's 5s limit", false),
    ])
    func means(_ line: String, expected: Bool) {
        #expect(NoDisplaySignal.means(line) == expected)
    }

    @Test("The first such line is told, once")
    func toldOnce() {
        let heard = HeardLines()
        let signal = NoDisplaySignal { heard.add($0) }
        signal.check("0130:err:vulkan:vulkan_init_once Failed to load libvulkan.1.dylib")
        #expect(!signal.seen)
        signal.check("015c:err:macdrv:macdrv_init Failed to start Cocoa app main loop")
        signal.check("015c:err:winediag:nodrv_CreateWindow Application tried to create a window, but no driver could be loaded.")
        #expect(signal.seen)
        #expect(heard.all == ["015c:err:macdrv:macdrv_init Failed to start Cocoa app main loop"])
    }
}

private nonisolated final class HeardLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
