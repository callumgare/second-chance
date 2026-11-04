import Foundation
import Testing
@testable import SCKit
import WrappBuilder

/// Second Chance's `EMIT` strings: the app's Swift is what the vocabulary
/// makes, and every shipped bundle's `EMIT`s are in it, in order.
struct EmitVocabularyTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func vocabulary() throws -> EmitVocabulary {
        try EmitVocabulary.load(root.appendingPathComponent(EmitVocabularySource.vocabularyPath))
    }

    @Test func theGeneratedSwiftIsCurrent() throws {
        let checkedIn = try String(contentsOf: Self.root.appendingPathComponent(EmitVocabularySource.path), encoding: .utf8)
        #expect(EmitVocabularySource.source(for: try Self.vocabulary()) == checkedIn,
                "\(EmitVocabularySource.path) is stale: run `sc generate`")
    }

    @Test("Every shipped bundle's EMITs are strings Second Chance reads, its phases never going back")
    func shippedBundlesEmitWhatSecondChanceReads() throws {
        let vocabulary = try Self.vocabulary()
        let modules = try ModuleLoader(root: Self.root.appendingPathComponent("Modules")).loadAll().get()
        let loader = try ProgramBundleLoader(root: Self.root.appendingPathComponent("Bundles"), modules: modules)
        for bundle in try loader.loadAll().get() {
            let wrappfile = try WrappfileParser.parse(String(contentsOf: bundle.folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
            let planner = BuildPlanner(bundle: bundle, wrappfile: wrappfile, modules: modules)
            for edition in bundle.manifest.editions {
                guard let plan = try planner.plan(edition: edition.id, conditions: .thisMac) else { continue }
                #expect(vocabulary.problems(in: plan) == [], "\(bundle.manifest.id) \(edition.id)")
            }
        }
    }
}
