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
    /// A wrapp whose `wine` is a shell script printing `output` and exiting
    /// with `exitCode`.
    private func fakeWrapp(output: String, exitCode: Int32) throws -> URL {
        let wrapp = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-display-\(UUID().uuidString).app")
        let bin = wrapp.appendingPathComponent("Contents/SharedSupport/wine/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = bin.appendingPathComponent("wine")
        try "#!/bin/sh\necho '\(output)' >&2\nexit \(exitCode)\n".write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        return wrapp
    }

    @Test("Wine's nodrv_CreateWindow error fails the run even when the program exits 0")
    func noDisplayFails() async throws {
        let wrapp = try fakeWrapp(
            output: "0428:err:winediag:nodrv_CreateWindow Application tried to create a window, but no driver could be loaded.",
            exitCode: 0
        )
        defer { try? FileManager.default.removeItem(at: wrapp) }

        await #expect(throws: WineError.self) {
            try await WineEnvironment(appPath: wrapp).runWine(executable: "wine", arguments: ["AutoIt3.exe"])
        }
        do {
            try await WineEnvironment(appPath: wrapp).runWine(executable: "wine", arguments: ["AutoIt3.exe"])
        } catch WineError.noDisplay {
            // Expected.
        } catch {
            Issue.record("Expected WineError.noDisplay, got \(error)")
        }
    }

    @Test("Other error lines leave a clean exit alone")
    func otherErrorsPass() async throws {
        let wrapp = try fakeWrapp(
            output: "0080:err:environ:init_peb starting L\"C:\\\\setup.exe\" in experimental wow64 mode",
            exitCode: 0
        )
        defer { try? FileManager.default.removeItem(at: wrapp) }

        try await WineEnvironment(appPath: wrapp).runWine(executable: "wine", arguments: ["setup.exe"])
    }
}
