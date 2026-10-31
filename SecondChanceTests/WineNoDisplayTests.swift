//
//  WineNoDisplayTests.swift
//  SecondChanceTests
//
//  A Wine program that found no display fails, whatever its exit code.

import Foundation
import Testing
@testable import SecondChance

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
