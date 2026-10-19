//
//  ProcessNameTests.swift
//  SecondChanceTests
//
//  The executable name in a `ps` command column.

import Foundation
import Testing
@testable import SecondChance

@Suite("Process name")
struct ProcessNameTests {
    @Test("Finds the executable whatever form ps reports it in", arguments: [
        // Wine 9 and macOS programs
        ("Alibi.exe", "Alibi.exe"),
        ("/usr/bin/yes", "yes"),
        ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "Google Chrome"),
        ("/var/folders/xx/T//winetemp-1/Game.exe", "Game.exe"),
        // Wine 10: the Windows path, with a trailing space
        (#"C:\Program Files (x86)\Her Interactive\Nancy Drew Alibi in Ashes\Alibi.exe "#, "Alibi.exe"),
        (#"C:\windows\system32\start.exe"#, "start.exe"),
        ("start.exe", "start.exe"),
    ])
    func executable(command: String, expected: String) {
        #expect(ProcessName.executable(fromPSCommand: command) == expected)
    }
}
