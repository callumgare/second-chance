//
//  InstallStallTests.swift
//  SecondChanceTests
//
//  When an unattended install counts as stalled, how runWine's wait answers
//  its watchdog, and which windows count as the installer asking something.

import CoreGraphics
import Foundation
import Testing
@testable import SecondChance

@Suite("A stalled install")
struct InstallStallTests {
    @Test("The window comes from SECOND_CHANCE_INSTALL_STALL_SECONDS, and 0 turns the watch off")
    func ruleFromEnvironment() {
        #expect(InstallStallRule.fromEnvironment([:]) == InstallStallRule(window: InstallStallRule.defaultWindow))
        #expect(InstallStallRule.fromEnvironment(["SECOND_CHANCE_INSTALL_STALL_SECONDS": "30"]) == InstallStallRule(window: 30))
        #expect(InstallStallRule.fromEnvironment(["SECOND_CHANCE_INSTALL_STALL_SECONDS": "0"]) == nil)
    }

    @Test("A heavily loaded Mac gets three times as long")
    func heavyLoad() {
        let rule = InstallStallRule(window: 100)
        #expect(!rule.isStalled(quietFor: 99, heavyLoad: false))
        #expect(rule.isStalled(quietFor: 100, heavyLoad: false))
        #expect(!rule.isStalled(quietFor: 299, heavyLoad: true))
        #expect(rule.isStalled(quietFor: 300, heavyLoad: true))
    }

    @Test("CPU, a new program and output are progress; Steam's own signs aren't")
    func progressSigns() {
        #expect(InstallStallRule.isProgress(.cpu))
        #expect(InstallStallRule.isProgress(.newProcess("setup.exe")))
        #expect(InstallStallRule.isProgress(.output))
        #expect(!InstallStallRule.isProgress(.steamCPU))
        #expect(!InstallStallRule.isProgress(.steamLog))
    }

    // MARK: runWine's wait

    @Test("A program that exits ends the wait")
    func exits() {
        // Signalled, as the termination handler does; a semaphore made with a
        // value above zero traps when freed below it.
        let exited = DispatchSemaphore(value: 0)
        exited.signal()
        #expect(WineEnvironment.wait(for: exited, timeout: 5, watchdog: FakeWatchdog([]), tick: 0.01) == .exited)
    }

    @Test("A stalled verdict ends the wait at once")
    func stalls() {
        let watchdog = FakeWatchdog([.carryOn, .stalled(quietFor: 120)])
        #expect(WineEnvironment.wait(for: DispatchSemaphore(value: 0), timeout: nil, watchdog: watchdog, tick: 0.01)
                == .stalled(quietFor: 120))
    }

    @Test("Time waiting on the person doesn't count towards the timeout")
    func waitingOnPersonHoldsTheTimeout() {
        // Three ticks of 0.01 s against a 0.02 s timeout: the two spent
        // waiting on the person don't count, so the third, carrying on, times
        // it out only after the fourth.
        let watchdog = FakeWatchdog([.waitingOnPerson, .waitingOnPerson, .carryOn, .carryOn])
        #expect(WineEnvironment.wait(for: DispatchSemaphore(value: 0), timeout: 0.02, watchdog: watchdog, tick: 0.01) == .timedOut)
        #expect(watchdog.checks == 4)
    }

    @Test("Without a watchdog, the timeout alone ends it")
    func noWatchdog() {
        #expect(WineEnvironment.wait(for: DispatchSemaphore(value: 0), timeout: 0.01, watchdog: nil) == .timedOut)
    }

    // MARK: The installer's window

    @Test("Only a Wine program's normal, real-sized window counts as the installer asking something")
    func installerWindow() {
        func window(pid: pid_t, layer: Int = 0, width: CGFloat = 400, height: CGFloat = 300, owner: String = "setup.exe") -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer, kCGWindowOwnerName as String: owner,
             kCGWindowBounds as String: ["X": CGFloat(0), "Y": CGFloat(0), "Width": width, "Height": height]]
        }
        let wine: Set<pid_t> = [100]
        #expect(InstallStallWatch.onScreenWindowOwner(in: [window(pid: 200)], winePids: wine) == nil)
        #expect(InstallStallWatch.onScreenWindowOwner(in: [window(pid: 100, layer: 25)], winePids: wine) == nil)
        #expect(InstallStallWatch.onScreenWindowOwner(in: [window(pid: 100, width: 1, height: 1)], winePids: wine) == nil)
        #expect(InstallStallWatch.onScreenWindowOwner(in: [window(pid: 200), window(pid: 100)], winePids: wine)?.pid == 100)
    }
}

/// Gives the verdicts it was made with, one per check, then carries on.
private final class FakeWatchdog: WineWatchdog, @unchecked Sendable {
    private var verdicts: [WineWatchdogVerdict]
    private(set) var checks = 0

    init(_ verdicts: [WineWatchdogVerdict]) {
        self.verdicts = verdicts
    }

    func sawOutput() {}

    func check() -> WineWatchdogVerdict {
        checks += 1
        return verdicts.isEmpty ? .carryOn : verdicts.removeFirst()
    }
}
