//
//  WinePatchesTests.swift
//  WineKitTests
//
//  WINE.PATCH's patches, by name.

import Foundation
import Testing
@testable import WineExecutor
import WrappModuleKit

@Suite("Wine patches")
struct WinePatchesTests {
    @Test func eachPatchIsNamedAsItsFunctionIs() {
        #expect(WinePatch.all.keys.sorted() == ["keep-thread-handles", "skip-synth-playout"])
        #expect(WinePatch.all["keep-thread-handles"]?.revision == KeepThreadHandles.revision)
        #expect(WinePatch.all["skip-synth-playout"]?.revision == SkipSynthPlayout.revision)
    }

    @Test func namedPatchesComeInTheOrderGiven() throws {
        let patches = try WinePatch.named(["skip-synth-playout", "keep-thread-handles"], origin: "Wrappfile:3")
        #expect(patches.map(\.name) == ["skip-synth-playout", "keep-thread-handles"])
    }

    @Test func anUnknownPatchOrNoneIsARecipeFailure() {
        for names in [["no-such-patch"], []] {
            #expect {
                try WinePatch.named(names, origin: "Wrappfile:3")
            } throws: { error in
                guard case .recipe(let message) = error as? StepFailure else { return false }
                return message.hasPrefix("Wrappfile:3:")
            }
        }
    }

    @Test func applyingInATreeSaysWhetherItWasAlreadyMade() throws {
        let tree = try SkipSynthPlayoutTests.tree(prefixCopy: nil)
        defer { try? FileManager.default.removeItem(at: tree) }
        let patch = try #require(WinePatch.all["skip-synth-playout"])
        #expect(try patch.apply(tree) == false)
        #expect(try patch.apply(tree) == true)
    }
}
