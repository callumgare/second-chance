import Foundation
import Testing
@testable import SecondChance

@Suite("Wrapp loading stages")
struct LoadingStageTests {
    static let timed: [LoadingStage] = [
        .startingGame(title: "Danger by Design"),
        .startingSteam,
        .steamStartingGame(title: "Curse of Blackmoor Manor"),
    ]

    @Test("A stage says it's slow before it says it may have failed", arguments: timed)
    func slowBeforeFailure(stage: LoadingStage) throws {
        let slow = try #require(stage.slowNoteAfter)
        let failure = try #require(stage.possibleFailureAfter)
        #expect(slow < failure)
    }

    @Test("Waiting for the player to answer Steam never counts as slow",
          arguments: [LoadingStage.signingInToSteam, .steamPlayingElsewhere, .steamWaitingForPlayer])
    func waitingOnThePlayerHasNoClock(stage: LoadingStage) {
        #expect(stage.isWaitingOnThePlayer)
        #expect(stage.slowNoteAfter == nil)
        #expect(stage.possibleFailureAfter == nil)
        #expect(stage.subject == "Steam")
        let clock = LoadingClock(stage: stage, started: Date(timeIntervalSince1970: 0))
        #expect(!clock.isSlow(at: Date(timeIntervalSince1970: 86_400)))
        #expect(!clock.mayHaveFailed(at: Date(timeIntervalSince1970: 86_400)))
    }

    @Test("Each stage names what's loading")
    func namesWhatsLoading() {
        #expect(LoadingStage.startingSteam.message.contains("Steam"))
        #expect(LoadingStage.startingSteam.subject == "Steam")
        #expect(LoadingStage.steamStartingGame(title: "Old Clock").message.contains("Steam is starting Old Clock"))
        #expect(LoadingStage.steamStartingGame(title: "Old Clock").subject == "The game")
        #expect(LoadingStage.startingGame(title: "Old Clock").message.contains("Old Clock"))
        #expect(LoadingStage.updatingSteam(.downloading(doneKB: 1, totalKB: 2)).message == "Updating Steam…")
        #expect(LoadingStage.updatingSteam(.installing).message == "Installing Steam's update…")
        #expect(LoadingStage.updatingSteam(.installing).subject == "Steam")
    }

    @Test("An update's download shows its progress in megabytes")
    func updateProgress() throws {
        let stage = LoadingStage.updatingSteam(.downloading(doneKB: 222_163, totalKB: 255_438))
        let progress = try #require(stage.progress)
        #expect(progress.doneKB == 222_163)
        #expect(progress.totalKB == 255_438)
        #expect(stage.progressText == "216 of 249 MB")
        // Nothing to measure before the bootstrapper says how big it is.
        #expect(LoadingStage.updatingSteam(.downloading(doneKB: nil, totalKB: nil)).progress == nil)
        #expect(LoadingStage.updatingSteam(.extracting).progress == nil)
    }
}

@Suite("Loading window clock")
struct LoadingClockTests {
    let start = Date(timeIntervalSince1970: 1_000)

    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test("A launch that keeps showing progress isn't called a failure, however long it takes",
          arguments: LoadingStageTests.timed)
    func progressHoldsOffFailure(stage: LoadingStage) throws {
        var clock = LoadingClock(stage: stage, started: start)
        let quiet = try #require(stage.stallAfter)
        let failure = try #require(stage.possibleFailureAfter)
        // Progress a little more often than the stall limit, well past the stage's time.
        var time: TimeInterval = 0
        while time < failure * 4 {
            time += quiet / 2
            clock.note(.cpu, at: at(time))
            #expect(!clock.mayHaveFailed(at: at(time)))
        }
        // Then it stops.
        #expect(!clock.mayHaveFailed(at: at(time + quiet - 1)))
        #expect(clock.mayHaveFailed(at: at(time + quiet)))
    }

    @Test("A quiet launch isn't called a failure before the stage's time is up",
          arguments: LoadingStageTests.timed)
    func quietButEarly(stage: LoadingStage) throws {
        let clock = LoadingClock(stage: stage, started: start)
        let failure = try #require(stage.possibleFailureAfter)
        #expect(!clock.mayHaveFailed(at: at(failure - 1)))
        #expect(clock.mayHaveFailed(at: at(max(failure, try #require(stage.stallAfter)))))
    }

    @Test("A stalled update is one with no new line for 30 seconds, whenever it started")
    func stalledUpdate() {
        var clock = LoadingClock(stage: .updatingSteam(.downloading(doneKB: 10, totalKB: 100)), started: start)
        // Other activity doesn't count: only the update's own lines, each a new stage.
        clock.note(.cpu, at: at(20))
        clock.note(.steamLog, at: at(25))
        #expect(!clock.mayHaveFailed(at: at(29)))
        #expect(clock.mayHaveFailed(at: at(30)))
        #expect(!clock.isSlow(at: at(600)))
    }

    @Test("Connecting to Steam goes by time alone: offline, Steam keeps trying, and logging")
    func connectingByTime() throws {
        let stage = LoadingStage.connectingToSteam
        var clock = LoadingClock(stage: stage, started: start)
        let failure = try #require(stage.possibleFailureAfter)
        for second in stride(from: 1.0, to: failure, by: 1) {
            clock.note(.steamLog, at: at(second))
        }
        #expect(clock.mayHaveFailed(at: at(failure)))
        #expect(stage.possibleFailureText.contains("internet"))
    }

    @Test("A busy Mac gives a stage that needs the CPU longer, and leaves a download's 30 s alone")
    func heavyLoad() throws {
        let stage = LoadingStage.startingGame(title: "x")
        var clock = LoadingClock(stage: stage, started: start)
        clock.heavyLoad = true
        let failure = try #require(stage.possibleFailureAfter)
        let quiet = try #require(stage.stallAfter)
        let longer = max(failure, quiet) * LoadingStage.heavyLoadFactor
        #expect(!clock.mayHaveFailed(at: at(longer - 1)))
        #expect(clock.mayHaveFailed(at: at(longer)))

        var update = LoadingClock(stage: .updatingSteam(.downloading(doneKB: 1, totalKB: 2)), started: start)
        update.heavyLoad = true
        #expect(update.mayHaveFailed(at: at(30)))
    }

    @Test("A slow note comes at the stage's own time")
    func slowNote() throws {
        let stage = LoadingStage.startingGame(title: "x")
        let clock = LoadingClock(stage: stage, started: start)
        let slow = try #require(stage.slowNoteAfter)
        #expect(!clock.isSlow(at: at(slow - 1)))
        #expect(clock.isSlow(at: at(slow)))
    }

    @Test("Waiting for the last session to close offers its choices on time alone")
    func lastSession() {
        let clock = LoadingClock(stage: .lastSessionClosing, started: start)
        #expect(!clock.mayHaveFailed(at: at(2)))
        #expect(clock.mayHaveFailed(at: at(3)))
    }
}

@Suite("Launch activity")
struct LaunchActivityTests {
    typealias Snapshot = LaunchActivityMonitor.Snapshot

    @Test("ps's CPU times read as seconds", arguments: [
        ("0:00.19", 0.19), ("1:02.50", 62.5), ("1:00:00.00", 3600), ("2-01:00:00.00", 2 * 86_400 + 3600),
    ])
    func psTime(text: String, seconds: Double) throws {
        #expect(abs(try #require(Snapshot.seconds(fromPSTime: text)) - seconds) < 0.001)
    }

    @Test("Only Wine's programs and ScummVM are watched, by name")
    func whatIsWatched() {
        let snapshot = Snapshot(psOutput: """
          101   0:01.00 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
          202   0:00.30 /tmp/X.app/Contents/SharedSupport/wine/bin/wineserver
          203   0:00.14 C:\\windows\\system32\\explorer.exe
          204   0:02.00 C:\\Program Files (x86)\\Nancy Drew SCK\\Secrets.exe
          305   0:03.00 /tmp/Y.app/Contents/MacOS/scummvm
        """)
        // Not the server, whose CPU is mostly its work for the wrapp's own checks.
        #expect(snapshot.names == ["explorer.exe", "secrets.exe", "scummvm"])
        #expect(snapshot.cpu[101] == nil)
    }

    @Test("The wrapp's own checks on Wine's desktop aren't signs of progress")
    func ownChecksIgnored() {
        let snapshot = Snapshot(psOutput: """
          210   0:00.40 C:\\windows\\system32\\reg.exe
          211   0:00.10 C:\\windows\\system32\\conhost.exe
          212   0:00.19 /tmp/X.app/Contents/SharedSupport/wine/bin/wine
        """)
        #expect(snapshot.names.isEmpty)
    }

    @Test("Steam's own programs' CPU is counted apart from the game's")
    func steamApart() {
        let before = Snapshot(psOutput: """
          301   0:10.00 C:\\Program Files (x86)\\Steam\\steam.exe
          302   0:20.00 C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\steamwebhelper.exe
        """)
        let after = Snapshot(psOutput: """
          301   0:10.50 C:\\Program Files (x86)\\Steam\\steam.exe
          302   0:20.30 C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\steamwebhelper.exe
          303   0:00.20 C:\\Program Files (x86)\\Steam\\steamapps\\common\\Nancy Drew\\Game.exe
        """)
        #expect(abs(after.cpuUsed(since: before) - 0.2) < 0.001)
        #expect(abs(after.cpuUsed(since: before, steam: true) - 0.8) < 0.001)
        // Steam busy on its own is no sign the game is getting anywhere.
        #expect(!LoadingStage.steamStartingGame(title: "x").countsAsProgress(.steamCPU))
        #expect(LoadingStage.steamStartingGame(title: "x").countsAsProgress(.steamLaunchStep))
    }

    @Test("CPU used between samples counts what each program added, and all of a new one's")
    func cpuUsed() {
        let before = Snapshot(psOutput: """
          202   0:00.30 C:\\windows\\system32\\winedevice.exe
          203   0:00.14 C:\\windows\\system32\\explorer.exe
        """)
        let after = Snapshot(psOutput: """
          202   0:00.40 C:\\windows\\system32\\winedevice.exe
          203   0:00.14 C:\\windows\\system32\\explorer.exe
          204   0:00.25 C:\\Program Files (x86)\\Nancy Drew SCK\\Secrets.exe
        """)
        #expect(abs(after.cpuUsed(since: before) - 0.35) < 0.001)
        // An idle session uses nothing; a program that went doesn't count against it.
        #expect(before.cpuUsed(since: after) == 0)
    }
}
