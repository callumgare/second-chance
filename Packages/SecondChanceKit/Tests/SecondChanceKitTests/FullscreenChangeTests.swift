import Foundation
import Logging
import Testing
@testable import SecondChanceKit

/// Native fullscreen's reports of who moved the game's window into or out
/// of its Space, which the wrapp keeps the last of
/// (docs/wine-in-process-helpers.md#the-players-choice-kept).
@Suite("Fullscreen changes")
struct FullscreenChangeTests {
    private let logger = Logger(label: "au.gare.callum.second-chance.SecondChanceKitTests.FullscreenChange")

    @Test("The session keeps the last change, and who made it")
    func keepsLast() {
        let report = InProcessHelperReport(armingVariables: [:], logger: logger)
        #expect(report.lastFullscreenChange == nil)
        report.observe(line: "second-chance-helper[NativeFullscreen] notice: armed in icytower13.exe")
        report.observe(line: "second-chance-helper[NativeFullscreen] notice: entering native fullscreen: 'Icy Tower' 640x480 (the game set a display mode)")
        #expect(report.lastFullscreenChange == nil)
        report.observe(line: "second-chance-helper[NativeFullscreen] notice: fullscreen changed by the game: fullscreen")
        #expect(report.lastFullscreenChange == .init(fullscreen: true, byPlayer: false))
        report.observe(line: "second-chance-helper[NativeFullscreen] notice: fullscreen changed by the player: windowed")
        #expect(report.lastFullscreenChange == .init(fullscreen: false, byPlayer: true))
        report.observe(line: "second-chance-helper[NativeFullscreen] notice: fullscreen changed by the game: fullscreen (the window was in its Space already)")
        #expect(report.lastFullscreenChange == .init(fullscreen: true, byPlayer: false))
        // Forced by the launch: not the player's either.
        report.observe(line: "second-chance-helper[NativeFullscreen] notice: fullscreen changed by the launch: windowed")
        #expect(report.lastFullscreenChange == .init(fullscreen: false, byPlayer: false))
    }

    @Test("Another helper's line, or one that names no state, changes nothing")
    func ignoresOthers() {
        let report = InProcessHelperReport(armingVariables: [:], logger: logger)
        report.observe(line: "second-chance-helper[CursorLock] notice: fullscreen changed by the player: fullscreen")
        report.observe(line: "second-chance-helper[NativeFullscreen] notice: fullscreen changed by the player: sideways")
        report.observe(line: "fullscreen changed by the player: fullscreen")
        #expect(report.lastFullscreenChange == nil)
    }
}
