//
//  DocsTableTests.swift
//  SecondChanceTests
//
//  AGENTS.md's Documentation table is the only index of `docs/`. These tests
//  keep it honest in both directions, so a doc can't be added without a row
//  and a row can't outlive the doc it points at.
//
//  The scan is recursive. A row naming a directory covers every doc beneath it,
//  so a category can be indexed once instead of file by file — except under
//  `docs/historical-plans/`, where each plan must be listed in its own right.

import Testing
import Foundation

@Suite("Docs table")
struct DocsTableTests {

    /// Every documentation file under `docs/`, at any depth, as a repo-relative
    /// path (e.g. `docs/historical-plans/some-plan.md`). Images are README
    /// assets rather than docs, so only `.md` counts.
    private static func docFilesOnDisk() throws -> [String] {
        let docsDir = TestPaths.repoRoot.appendingPathComponent("docs").standardizedFileURL
        let docsPath = docsDir.path

        guard let walker = FileManager.default.enumerator(
            at: docsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            Issue.record("Could not enumerate \(docsPath)")
            return []
        }

        var found: [String] = []
        for case let url as URL in walker {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(docsPath + "/") else { continue }
            found.append("docs/" + path.dropFirst(docsPath.count + 1))
        }
        return found.sorted()
    }

    /// Docs under here must each be listed individually: the
    /// `docs/historical-plans/` row describes the category but does not stand
    /// in for the plans themselves, so every frozen plan stays findable from
    /// the table.
    private static let requiresOwnRow = "docs/historical-plans/"

    /// Whether the table accounts for `file` — by naming it outright, or (for
    /// everything outside `requiresOwnRow`) by naming an ancestor directory.
    private static func coveringRow(for file: String, in rows: Set<String>) -> String? {
        if rows.contains(file) { return file }
        guard !file.hasPrefix(requiresOwnRow) else { return nil }

        var components = file.split(separator: "/").map(String.init)
        components.removeLast()  // drop the filename
        while !components.isEmpty {
            let dir = components.joined(separator: "/")
            if rows.contains(dir + "/") { return dir + "/" }
            if rows.contains(dir) { return dir }
            components.removeLast()
        }
        return nil
    }

    /// The `YYYY-MM-DD` a historical-plan filename leads with, or `nil` when it
    /// doesn't lead with one followed by an actual name.
    private static func leadingDateStamp(of filename: String) -> String? {
        let parts = filename.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }

        let digits = [(parts[0], 4), (parts[1], 2), (parts[2], 2)]
        for (part, width) in digits {
            guard part.count == width, part.allSatisfy({ $0.isNumber }) else { return nil }
        }
        // Something has to follow the stamp: "2026-09-03-.md" is not a name.
        guard parts[3].hasSuffix(".md"), parts[3].count > ".md".count else { return nil }

        return "\(parts[0])-\(parts[1])-\(parts[2])"
    }

    /// Whether `stamp` is a real calendar date, so `2026-13-45` is rejected.
    private static func isRealDate(_ stamp: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: stamp) != nil
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

    @Test("Every doc under docs/, at any depth, is covered by the AGENTS.md table")
    func everyDocIsListed() throws {
        let onDisk = try Self.docFilesOnDisk()
        let listed = try Self.docsInTable()

        let uncovered = onDisk.filter { Self.coveringRow(for: $0, in: listed) == nil }
        #expect(
            uncovered.isEmpty,
            """
            These exist under docs/ but nothing in AGENTS.md's Documentation \
            table accounts for them: \(uncovered.joined(separator: ", ")). Add a \
            row for each file, or a row for a directory containing them — except \
            under docs/historical-plans/, where every plan needs its own row.
            """
        )
    }

    @Test("Subdirectory docs are reached, not just the top level")
    func subdirectoryDocsAreScanned() throws {
        let onDisk = try Self.docFilesOnDisk()
        // Guards the recursion itself: if docFilesOnDisk ever stops descending,
        // everyDocIsListed would pass vacuously for nested files.
        #expect(
            onDisk.contains { $0.dropFirst("docs/".count).contains("/") },
            """
            No docs found below the top level of docs/. Either the tree is flat \
            (fine — delete this test) or the enumeration stopped recursing \
            (not fine).
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

    @Test("Historical plans lead with their implementation date")
    func historicalPlansAreDateStamped() throws {
        let plans = try Self.docFilesOnDisk()
            .filter { $0.hasPrefix("docs/historical-plans/") }

        var problems: [String] = []
        for plan in plans {
            let filename = URL(fileURLWithPath: plan).lastPathComponent
            guard let stamp = Self.leadingDateStamp(of: filename) else {
                problems.append("\(plan) — needs a YYYY-MM-DD- prefix")
                continue
            }
            if !Self.isRealDate(stamp) {
                problems.append("\(plan) — '\(stamp)' is not a real date")
            }
        }

        #expect(
            problems.isEmpty,
            """
            Historical-plan filenames must lead with the implementation date so \
            the directory sorts chronologically (AGENTS.md, "Keeping the docs \
            current"): \(problems.joined(separator: "; ")).
            """
        )
    }
}
