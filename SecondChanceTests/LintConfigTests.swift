//
//  LintConfigTests.swift
//  SecondChanceTests
//
//  SwiftLint skips a folder named in `.swiftlint.yml` that doesn't exist without
//  a word, so a moved folder silently drops out of linting (as `Shared/` did
//  when the shared code became `Packages/`). These keep the config's paths in
//  step with the tree.

import Foundation
import Testing

@Suite("SwiftLint config")
struct LintConfigTests {

    /// The paths listed under a top-level key or a custom rule's `included:`.
    /// A deliberately small reader: `.swiftlint.yml` only uses `- path` lists.
    private static func listedPaths() throws -> [String] {
        let config = try String(contentsOf: TestPaths.repoRoot.appendingPathComponent(".swiftlint.yml"), encoding: .utf8)
        var paths: [String] = []
        var inIncluded = false
        for line in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") {
                inIncluded = trimmed == "included:"
                continue
            }
            guard inIncluded, trimmed.hasPrefix("- ") else {
                if !trimmed.isEmpty, !trimmed.hasPrefix("#") { inIncluded = false }
                continue
            }
            paths.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
        }
        return paths
    }

    @Test("Every folder SwiftLint is told to include exists")
    func includedPathsExist() throws {
        let paths = try Self.listedPaths()
        #expect(paths.contains("Packages"), "The shared packages must be linted")
        for path in paths {
            let url = TestPaths.repoRoot.appendingPathComponent(path)
            #expect(FileManager.default.fileExists(atPath: url.path), "\(path) is in .swiftlint.yml but doesn't exist")
        }
    }
}
