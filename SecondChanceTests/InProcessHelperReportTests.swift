import Foundation
import Testing
import Logging
@testable import SecondChance

@Suite("In-process helper report")
struct InProcessHelperReportTests {
    private let logger = Logger(label: "au.gare.callum.second-chance.SecondChanceTests.InProcessHelperReport")
    /// An .exe that isn't there: its graphics are unknown, so every helper arms.
    private let unreadableExe = URL(fileURLWithPath: "/nonexistent/Game.exe")

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
            armingVariables: WineEnvironment.inProcessHelperVariables(gameExe: unreadableExe), logger: logger)
        report.observe(line: "second-chance-helper[CursorLock] notice: armed in Game.exe")
        report.observe(line: "second-chance-helper[NativeFullscreen] notice: entering native fullscreen: 'x' 640x480")
        #expect(report.check() == [.nativeFullscreen])
        // Once only: the deadline's check and a later one don't both report.
        #expect(report.check() == [])
    }

    @Test("Puppet control is armed only when WrappPuppeteer gave the wrapp a directory")
    func armsPuppetControlOnlyForWrappPuppeteer() {
        let player = WineEnvironment.inProcessHelperVariables(gameExe: unreadableExe, environment: [:])
        #expect(player["PUPPET_CONTROL_EXE"] == nil)
        #expect(player["CURSOR_LOCK_EXE"] == "Game.exe")
        let puppeteer = WineEnvironment.inProcessHelperVariables(
            gameExe: unreadableExe, environment: ["SECOND_CHANCE_PUPPET_DIR": "/tmp/wrapp-puppeteer-1"])
        #expect(puppeteer["PUPPET_CONTROL_EXE"] == "Game.exe")
        #expect(InProcessHelperReport(armingVariables: puppeteer, logger: logger).check() == [.nativeFullscreen, .cursorLock, .puppetControl])
    }

    @Test("A wrapp shows Wine the display below the notch unless native fullscreen is off")
    func belowNotchFollowsNativeFullscreen() {
        #expect(WineEnvironment.wrappSessionVariables(environment: [:]) == ["NATIVE_FULLSCREEN_BELOW_NOTCH": "1"])
        #expect(WineEnvironment.wrappSessionVariables(environment: ["SECOND_CHANCE_NATIVE_FULLSCREEN": "0"]) == [:])
    }

    @Test("A helper switched off isn't expected to arm")
    func ignoresHelpersNotArmed() {
        let report = InProcessHelperReport(armingVariables: ["CURSOR_LOCK_EXE": "Game.exe"], logger: logger)
        report.observe(line: "second-chance-helper[CursorLock] notice: armed in Game.exe")
        #expect(report.check() == [])
    }
}
