//
//  ProcessListTests.swift
//  SecondChanceTests
//
//  Reading what's running from ps.

import Foundation
import Testing
@testable import ProcessKit
@testable import WindowsFormats
@testable import WineKit
@testable import WrappFormat
@testable import WrappLogging

@Suite("Process list")
struct ProcessListTests {
    private let processes = ProcessList(psOutput: """
        1     0   0.0   1:00.00 2-00:00:00 /sbin/launchd
      300     1  12.5   0:01.50     01:30 /tmp/X.app/Contents/SharedSupport/wine/bin/wineserver
      301   300   2.0   0:00.20     01:29 C:\\windows\\system32\\explorer.exe
      302   301  45.0   1:02.50     01:00 C:\\Program Files (x86)\\Nancy Drew\\Game.exe
      400     1  99.0   0:10.00     00:05 /usr/bin/yes
    """)

    @Test("Every column is read, and a command keeps its spaces")
    func columns() throws {
        let game = try #require(processes.entries.first { $0.pid == 302 })
        #expect(game.parent == 301)
        #expect(game.cpuPercent == 45)
        #expect(abs(game.cpuSeconds - 62.5) < 0.001)
        #expect(game.elapsedSeconds == 60)
        #expect(game.command == #"C:\Program Files (x86)\Nancy Drew\Game.exe"#)
        #expect(game.name == "Game.exe")
        let launchd = try #require(processes.entries.first)
        #expect(launchd.elapsedSeconds == 172_800.0)
    }

    @Test("Wine's processes are told from the rest, and found by name")
    func wine() {
        #expect(processes.wine.map(\.pid) == [300, 301, 302])
        #expect(processes.named("game.EXE").map(\.pid) == [302])
        #expect(processes.named("steam.exe").isEmpty)
    }

    @Test("With a uid column, another user's processes are never this user's game or Wine")
    func otherUsers() throws {
        let me = getuid(), other = me + 1
        let list = ProcessList(psOutput: """
          300     1 \(me)  12.5   0:01.50     01:30 /tmp/X.app/Contents/SharedSupport/wine/bin/wineserver
          302   300 \(me)  45.0   1:02.50     01:00 C:\\Program Files (x86)\\Ski\\ski32.exe
          900     1 \(other)  50.0   0:30.00     00:40 /Users/Shared/Y.app/Contents/SharedSupport/wine/bin/wineserver
          902   900 \(other)  90.0   0:30.00     00:40 C:\\SkiFree\\ski32.exe
        """)
        let theirs = try #require(list.entries.first { $0.pid == 902 })
        #expect(theirs.uid == other)
        #expect(!theirs.isMine)
        #expect(theirs.command == #"C:\SkiFree\ski32.exe"#)
        #expect(list.named("SKI32.EXE").map(\.pid) == [302])
        #expect(list.wine.map(\.pid) == [300, 302])
        #expect(list.entries.count == 4)
    }

    @Test("Without a uid column, every process counts as this user's")
    func noUIDColumn() {
        #expect(processes.entries.allSatisfy { $0.uid == nil && $0.isMine })
    }

    @Test("A process descends from what started it, and what started that")
    func descends() {
        #expect(processes.descends(302, from: 300))
        #expect(processes.descends(300, from: 300))
        #expect(!processes.descends(400, from: 300))
    }
}
