//
//  DocsTableTests.swift
//  SecondChanceTests
//
//  AGENTS.md's Documentation table is the only index of `docs/`. These tests
//  keep it honest in both directions, so a doc can't be added without a row
//  and a row can't outlive the doc it points at.

import Testing
import Foundation

@Suite("Docs table")
struct DocsTableTests {

    /// Everything under `docs/` that counts as documentation: `.md` files and
    /// directories. Images are README assets, not docs, so they're excluded.
    private static func docsOnDisk() throws -> Set<String> {
        let docsDir = TestPaths.repoRoot.appendingPathComponent("docs")
        let entries = try FileManager.default.contentsOfDirectory(
            at: docsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        var found: Set<String> = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }

            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                found.insert("docs/\(name)/")
            } else if entry.pathExtension.lowercased() == "md" {
                found.insert("docs/\(name)")
            }
        }
        return found
    }

    /// The link targets in AGENTS.md's Documentation table. Rows look like:
    /// `| [docs/thing/](docs/thing/) | Read it when … |`
    private static func docsInTable() throws -> Set<String> {
        let agents = TestPaths.repoRoot.appendingPathComponent("AGENTS.md")
        let text = try String(contentsOf: agents, encoding: .utf8)

        // Only scan the Documentation section, so unrelated tables and links
        // elsewhere in AGENTS.md can't register as rows.
        guard let sectionStart = text.range(of: "\n## Documentation\n") else {
            Issue.record("AGENTS.md has no '## Documentation' section")
            return []
        }
        let afterStart = text[sectionStart.upperBound...]
        let section = afterStart.range(of: "\n## ").map { String(afterStart[..<$0.lowerBound]) }
            ?? String(afterStart)

        var targets: Set<String> = []
        for line in section.split(separator: "\n") {
            guard line.hasPrefix("|") else { continue }
            // Skip the header and the |---|---| delimiter row.
            if line.contains("---") { continue }
            // Pull every markdown link target on the row.
            var rest = Substring(line)
            while let open = rest.range(of: "]("),
                  let close = rest[open.upperBound...].firstIndex(of: ")") {
                targets.insert(String(rest[open.upperBound..<close]))
                rest = rest[rest.index(after: close)...]
            }
        }
        return targets
    }

    @Test("Every doc under docs/ has a row in the AGENTS.md table")
    func everyDocIsListed() throws {
        let onDisk = try Self.docsOnDisk()
        let listed = try Self.docsInTable()

        let missing = onDisk.subtracting(listed).sorted()
        #expect(
            missing.isEmpty,
            """
            These exist under docs/ but have no row in AGENTS.md's Documentation \
            table: \(missing.joined(separator: ", ")). Add a row saying when to \
            read each one.
            """
        )
    }

    @Test("Every row in the AGENTS.md table points at something that exists")
    func everyRowResolves() throws {
        let listed = try Self.docsInTable()

        var dangling: [String] = []
        for target in listed.sorted() {
            let path = TestPaths.repoRoot.appendingPathComponent(target).path
            if !FileManager.default.fileExists(atPath: path) {
                dangling.append(target)
            }
        }

        #expect(
            dangling.isEmpty,
            """
            AGENTS.md's Documentation table links to paths that don't exist: \
            \(dangling.joined(separator: ", ")).
            """
        )
    }

    @Test("The table is not empty")
    func tableHasRows() throws {
        let listed = try Self.docsInTable()
        #expect(!listed.isEmpty, "AGENTS.md's Documentation table has no doc rows")
    }
}
