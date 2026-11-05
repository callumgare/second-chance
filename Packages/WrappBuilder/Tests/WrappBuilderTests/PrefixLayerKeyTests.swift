//
//  PrefixLayerKeyTests.swift
//  WrappBuilderTests
//
//  The wine module's prefix stage, as every prefix is made.

import Foundation
import Testing
@testable import WrappBuilder

@Suite("Wine prefix stage")
struct PrefixLayerKeyTests {
    @Test func theStageIsTodaysInOrder() throws {
        let stage = try WineBuild.prefixStage(modules: modulesRoot)
        #expect(stage.steps.map(\.instruction) == ["ENGINE", "HELPERS", "PREFIX", "DRIVES", "REGISTRY", "WINETRICKS"])
        // What the progress screen says for each, before the step it's for.
        #expect(stage.emits.map(\.text) == ["second-chance.substep.display", "second-chance.substep.disc"])
        #expect(stage.emits.map { stage.steps[$0.before].instruction } == ["REGISTRY", "WINETRICKS"])
    }
}
