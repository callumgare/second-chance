//
//  UIStateShotsTests.swift
//  SecondChanceTests
//
//  Which catalogued states `sc screenshot --state` picks.

import Testing
@testable import SecondChanceKit

@Suite("Picking catalogued UI states")
struct UIStateShotsTests {
    @Test("A name picks only that state; one ending in * picks those starting with it")
    func matching() {
        #expect(UIStateShots.matches("welcome", "welcome"))
        #expect(!UIStateShots.matches("welcome-back", "welcome"))
        #expect(UIStateShots.matches("steam-stuck", "steam-*"))
        #expect(!UIStateShots.matches("error-steam-stuck", "steam-*"))
    }
}
