//
//  TestData.swift
//  WrappPuppeteer
//
//  Where a wrapp's test comes from: its program bundle's `tests` — the
//  scenario a module has, its parameters, and the needles of the bundle and
//  that module.

import Foundation
import GameCatalog
import SecondChanceKit
import WrappBuilder

/// The program bundles and modules WrappPuppeteer reads tests from: the
/// source tree's when it runs from a build inside it, else the copies in its
/// bundle. The source tree goes first because a build keeps a needle that
/// was since deleted or renamed, and doesn't pick up one just made until it
/// is rebuilt.
enum TestData {
    static let bundles: URL? = folder("Bundles")
    static let modules: URL? = folder("Modules")

    private static func folder(_ name: String) -> URL? {
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("nancy-drew").path) { return candidate }
        }
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: bundled.path) else { return nil }
        return bundled
    }

    /// The test of `program` (`nancy-drew/old-clock`).
    static func test(forProgram program: String) throws -> ProgramTest {
        guard let bundles, let modules else { throw ScenarioError(description: "no Bundles or Modules folder beside WrappPuppeteer") }
        // An extra bundle's (`sc --bundle`) in place of the shipped one.
        return try ProgramTest.load(bundleFolder: ExtraBundles.folder(of: program, shippedRoot: bundles), modulesRoot: modules)
    }

    /// The program a wrapp is of: its lock's bundle, or, for a wrapp from
    /// before locks, the Nancy Drew game its settings name.
    static func program(of wrapp: Wrapp) -> String {
        let layout = WrappLayout(app: URL(fileURLWithPath: wrapp.appPath))
        if let lock = try? WrappLock(of: layout) { return lock.bundle.id }
        return GameInfoProvider.shared.gameInfo(for: wrapp.gameSlug).programID
    }

    /// One module's needles alone, for looking at a screenshot with no game
    /// in mind (`--analyze`).
    static func moduleNeedles(_ module: String) throws -> NeedleLibrary {
        guard let modules else { throw ScenarioError(description: "no Modules folder beside WrappPuppeteer") }
        return try NeedleLibrary.load([modules.appendingPathComponent(module).appendingPathComponent("needles")])
    }
}
