//
//  WineRegistryTests.swift
//  SecondChanceTests
//
//  What `wine.registry` asks Wine's `reg` to do, and the winetricks verbs a
//  prefix is set up with. Wine is a pair of shell scripts (`FakeWine`).

import Foundation
import Testing
@testable import SecondChance
@testable import SecondChanceKit

@Suite("Wine registry and winetricks")
struct WineRegistryTests {
    @Test("Setting a value is one reg add, with its type")
    func set() async throws {
        let fake = try FakeWine()
        defer { fake.remove() }
        try await fake.wine.registry.set(.string("Y"), for: "EmulateModeset", in: .x11Driver)
        try await fake.wine.registry.set(.dword(7), for: "Count", in: "HKCU\\Software\\Test")
        #expect(fake.recorded("wine") == [
            #"[reg] [add] [HKEY_CURRENT_USER\Software\Wine\X11 Driver] [/v] [EmulateModeset] [/t] [REG_SZ] [/d] [Y] [/f]"#,
            #"[reg] [add] [HKCU\Software\Test] [/v] [Count] [/t] [REG_DWORD] [/d] [7] [/f]"#,
        ])
    }

    @Test("A drive's type goes in Wine's drives key")
    func driveType() async throws {
        let fake = try FakeWine()
        defer { fake.remove() }
        try await fake.wine.registry.set(.string("cdrom"), for: "d:", in: .wineDrives)
        #expect(fake.recorded("wine") == [#"[reg] [add] [HKEY_LOCAL_MACHINE\Software\Wine\Drives] [/v] [d:] [/t] [REG_SZ] [/d] [cdrom] [/f]"#])
    }

    @Test("Importing a file is reg import")
    func importFile() async throws {
        let fake = try FakeWine()
        defer { fake.remove() }
        try await fake.wine.registry.importFile(atWindowsPath: #"C:\steam.reg"#, timeout: 10)
        #expect(fake.recorded("wine") == [#"[reg] [import] [C:\steam.reg]"#])
    }

    @Test("Reading a key returns reg's listing")
    func values() async throws {
        let fake = try FakeWine(wine: #"echo '    \Device\Video0    REG_SZ    x'"#)
        defer { fake.remove() }
        let values = try await fake.wine.registry.values(in: .videoDeviceMap, timeout: 10)
        #expect(values.contains(#"\Device\Video0"#))
        #expect(fake.recorded("wine") == [#"[reg] [query] [HKLM\HARDWARE\DEVICEMAP\VIDEO]"#])
    }

    @Test("A read that times out stops only reg, not the Wine session")
    func valuesTimeoutLeavesSession() async throws {
        let fake = try FakeWine(wine: "sleep 30")
        defer { fake.remove() }
        await #expect(throws: WineError.timedOut(seconds: 0.3)) {
            _ = try await fake.wine.registry.values(in: .videoDeviceMap, timeout: 0.3)
        }
        #expect(fake.recorded("wineserver").isEmpty)
    }

    @Test("A winetricks verb is installed unattended")
    func winetricksVerb() async throws {
        let fake = try FakeWine()
        defer { fake.remove() }
        let calls = fake.wrapp.appendingPathComponent("winetricks-calls.txt")
        let script = try Self.script(in: fake, "echo \"$*\" > '\(calls.path)'")
        try await Winetricks(wine: fake.wine, script: script).install(.cncDdraw)
        #expect(try String(contentsOf: calls, encoding: .utf8) == "--unattended cnc_ddraw\n")
    }

    @Test("Winetricks failing says which verb")
    func winetricksFails() async throws {
        let fake = try FakeWine()
        defer { fake.remove() }
        let script = try Self.script(in: fake, "exit 1")
        await #expect(throws: WineError.winetricksFailed(trick: "isolate_home")) {
            try await Winetricks(wine: fake.wine, script: script).install(.isolateHome)
        }
        await #expect(throws: WineError.winetricksNotFound) {
            try await Winetricks(wine: fake.wine, script: nil).install(.isolateHome)
        }
    }

    /// A stand-in winetricks: a bash script with `body`.
    private static func script(in fake: FakeWine, _ body: String) throws -> URL {
        let script = fake.wrapp.appendingPathComponent("winetricks")
        try "#!/bin/bash\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        return script
    }
}
