import Testing
import Logging
@testable import SecondChance

@Suite("In-process helper report")
struct InProcessHelperReportTests {
    private let logger = Logger(label: "au.gare.callum.second-chance.SecondChanceTests.InProcessHelperReport")

    @Test("A helper's status line parses into helper, level and message")
    func parsesLine() throws {
        let line = try #require(InProcessHelperReport.Line("second-chance-helper[NativeFullscreen] warning: no eligible window after 90s; staying windowed"))
        #expect(line.helper == .nativeFullscreen)
        #expect(line.level == .warning)
        #expect(line.message == "no eligible window after 90s; staying windowed")
    }

    @Test("Other output isn't a status line", arguments: [
        "0124:err:module:import_dll Loading library Ndui.dll failed",
        "second-chance-helper[Unknown] notice: armed in Game.exe",
        "second-chance-helper[CursorLock] chatty: armed in Game.exe",
        "second-chance-helper[CursorLock] no level here",
    ])
    func ignoresOtherLines(_ text: String) {
        #expect(InProcessHelperReport.Line(text) == nil)
    }

    @Test("Every helper armed by its variable has to report arming")
    func reportsUnarmedHelpers() {
        let report = InProcessHelperReport(
            armingVariables: WineEnvironment.inProcessHelperVariables(gameExe: "Game.exe"), logger: logger)
        report.observe(line: "second-chance-helper[CursorLock] notice: armed in Game.exe")
        report.observe(line: "second-chance-helper[NativeFullscreen] notice: entering native fullscreen: 'x' 640x480")
        #expect(report.check() == [.nativeFullscreen])
        // Once only: the deadline's check and a later one don't both report.
        #expect(report.check() == [])
    }

    @Test("A helper switched off isn't expected to arm")
    func ignoresHelpersNotArmed() {
        let report = InProcessHelperReport(armingVariables: ["CURSOR_LOCK_EXE": "Game.exe"], logger: logger)
        report.observe(line: "second-chance-helper[CursorLock] notice: armed in Game.exe")
        #expect(report.check() == [])
    }
}
