import Foundation

/// Rewriting the version in `project.pbxproj`.
///
/// Only the targets that ship — SecondChance and WrappTemplate — track the
/// release. WrappPuppeteer and SecondChanceTests stay at 1.0. Each versioned
/// target's build configurations are found through its
/// XCConfigurationList (reading the UUIDs from the file rather than
/// hardcoding them survives Xcode regenerating them), and MARKETING_VERSION
/// and CURRENT_PROJECT_VERSION are rewritten only inside those blocks.
enum ProjectVersion {
    static let versionedTargets = ["SecondChance", "WrappTemplate"]

    /// Both targets have both keys in both configurations. Anything else
    /// means the project changed shape and this needs revisiting.
    static let expectedRewrites = 4

    /// The Debug/Release configuration UUIDs of the versioned targets.
    static func configurationIDs(in text: String) -> Set<String> {
        var ids = Set<String>()
        var inList = false
        for line in text.components(separatedBy: "\n") {
            if !inList {
                inList = versionedTargets.contains { line.contains("Build configuration list for PBXNativeTarget \"\($0)\" */ = {") }
                continue
            }
            if line.hasPrefix("\t\t};") {
                inList = false
                continue
            }
            if line.hasSuffix("/* Debug */,") || line.hasSuffix("/* Release */,") {
                if let id = line.split(separator: " ").first?.trimmingCharacters(in: .whitespaces) { ids.insert(id) }
            }
        }
        return ids
    }

    /// Calls `body` for each line, saying whether it is inside one of `ids`' blocks.
    private static func walk(_ text: String, ids: Set<String>, _ body: (String, Bool) -> String) -> String {
        var inBlock = false
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            if isConfigurationHeader(line) {
                let id = line.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                inBlock = ids.contains(id)
            }
            if inBlock, line.hasPrefix("\t\t\tname = ") { inBlock = false }
            out.append(body(line, inBlock))
        }
        return out.joined(separator: "\n")
    }

    /// `\t\t<UUID> /* Debug */ = {` or the same for Release.
    private static func isConfigurationHeader(_ line: String) -> Bool {
        guard line.hasPrefix("\t\t"), !line.hasPrefix("\t\t\t") else { return false }
        return line.hasSuffix(" /* Debug */ = {") || line.hasSuffix(" /* Release */ = {")
    }

    /// The marketing version the versioned targets are at now.
    static func current(in text: String) -> String? {
        let ids = configurationIDs(in: text)
        var found: String?
        _ = walk(text, ids: ids) { line, inBlock in
            if found == nil, inBlock, line.hasPrefix("\t\t\t\tMARKETING_VERSION = ") {
                found = String(line.dropFirst("\t\t\t\tMARKETING_VERSION = ".count)).replacingOccurrences(of: ";", with: "")
            }
            return line
        }
        return found
    }

    static func rewrite(_ text: String, version: String, build: String) throws -> String {
        let ids = configurationIDs(in: text)
        var marketing = 0
        var project = 0
        let result = walk(text, ids: ids) { line, inBlock in
            guard inBlock else { return line }
            if line.hasPrefix("\t\t\t\tMARKETING_VERSION = ") {
                marketing += 1
                return "\t\t\t\tMARKETING_VERSION = \(version);"
            }
            if line.hasPrefix("\t\t\t\tCURRENT_PROJECT_VERSION = ") {
                project += 1
                return "\t\t\t\tCURRENT_PROJECT_VERSION = \(build);"
            }
            return line
        }
        guard marketing == expectedRewrites, project == expectedRewrites else {
            throw SCError(
                "Expected \(expectedRewrites) MARKETING_VERSION and \(expectedRewrites) CURRENT_PROJECT_VERSION rewrites, made \(marketing) and \(project).",
                hints: ["project.pbxproj was left untouched. The project has changed shape; update ProjectVersion in Tools/sc."]
            )
        }
        return result
    }

    static func isSemanticVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
    }
}

/// CHANGELOG.md accumulates: a new section goes on top of what's there, so
/// previously released notes stay exactly as they were published.
enum Changelog {
    static let defaultHeader = """
    # Changelog

    All notable changes to Second Chance.


    """

    static func hasSection(for version: String, in text: String) -> Bool {
        text.components(separatedBy: "\n").contains { $0.hasPrefix("## \(version) ") }
    }

    /// `existing` with a `## <version> — <date>` section added above the newest release.
    static func adding(version: String, date: String, notes: String, to existing: String?) -> String {
        let section = "## \(version) — \(date)\n\n\(notes)\n\n"
        guard let existing else { return defaultHeader + section }
        let lines = existing.components(separatedBy: "\n")
        guard let firstRelease = lines.firstIndex(where: { $0.hasPrefix("## ") }) else {
            return existing + (existing.hasSuffix("\n") ? "" : "\n") + section
        }
        let header = lines[..<firstRelease].joined(separator: "\n")
        let releases = lines[firstRelease...].joined(separator: "\n")
        return header + "\n" + section + releases
    }

    /// `existing` with its `<version>` section — up to the next release's
    /// heading, or the end — swapped for a freshly generated one.
    static func replacing(version: String, date: String, notes: String, in existing: String) -> String {
        let lines = existing.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## \(version) ") }) else {
            return adding(version: version, date: date, notes: notes, to: existing)
        }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        let section = "## \(version) — \(date)\n\n\(notes)\n\n"
        let before = start == 0 ? "" : lines[..<start].joined(separator: "\n") + "\n"
        let after = lines[end...].joined(separator: "\n")
        return before + section + after
    }

    /// The notes under `<version>`'s heading, up to the next release's
    /// heading or the end, trimmed. Nil when there's no such section.
    static func section(for version: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## \(version) ") }) else { return nil }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        return lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drop leading blank lines from cog's output.
    static func trimLeadingBlankLines(_ text: String) -> String {
        // Like `sed '/./,$!d'` then `$(...)`: only empty lines go from the
        // front, trailing newlines from the end.
        var trimmed = Substring(text)
        while trimmed.hasPrefix("\n") { trimmed = trimmed.dropFirst() }
        while trimmed.hasSuffix("\n") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}
