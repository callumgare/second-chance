//
//  WrappTemplateTargetTests.swift
//  SecondChanceTests
//
//  The WrappTemplate target builds only the files its `membershipExceptions`
//  list names (AGENTS.md, "A new file in WrappTemplate/ must be listed").
//  A Swift file left off fails to compile somewhere far from the cause, or,
//  holding only an extension, not at all; a name left on after its file has
//  gone breaks the project. This keeps the list and the folder in step.

import Foundation
import Testing

@Suite("WrappTemplate target")
struct WrappTemplateTargetTests {
    /// The files the WrappTemplate target's exception set lists.
    private static func listed() throws -> [String] {
        let project = try String(contentsOf: TestPaths.repoRoot.appendingPathComponent("SecondChance.xcodeproj/project.pbxproj"),
                                 encoding: .utf8)
        let marker = try #require(project.range(of: #"/* Exceptions for "WrappTemplate" folder in "WrappTemplate" target */"#))
        let rest = project[marker.upperBound...]
        let start = try #require(rest.range(of: "membershipExceptions = ("))
        let end = try #require(rest[start.upperBound...].range(of: ");"))
        return rest[start.upperBound..<end.lowerBound]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t,\"")) }
            .filter { !$0.isEmpty }
    }

    /// The Swift files the target compiles: all in the folder, bar the
    /// in-process helpers' patcher, a script setup-wine.sh runs.
    private static func swiftFiles() throws -> [String] {
        let folder = TestPaths.repoRoot.appendingPathComponent("WrappTemplate")
        let walker = try #require(FileManager.default.enumerator(atPath: folder.path))
        return walker.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") && !$0.hasPrefix("InProcessHelpers/") }
    }

    @Test("Every Swift file in WrappTemplate/ is in the target, and everything listed exists")
    func listMatchesFolder() throws {
        let listed = try Self.listed()
        for file in try Self.swiftFiles() {
            #expect(listed.contains(file), "\(file) isn't in the WrappTemplate target's membershipExceptions, so it isn't built")
        }
        for entry in listed {
            let url = TestPaths.repoRoot.appendingPathComponent("WrappTemplate").appendingPathComponent(entry)
            #expect(FileManager.default.fileExists(atPath: url.path), "\(entry) is listed in the WrappTemplate target but doesn't exist")
        }
    }
}
