//
//  UnitTestSelection.swift
//  SCKit
//
//  Which unit suites `sc test unit <suite>…` runs, and where each lives.

import Foundation

/// The unit suites asked for by name, each found where it is declared: the
/// app's test target (run by xcodebuild), a local package's tests or sc's
/// own (each run by `swift test`). A name is a suite's type, `DocsTableTests`,
/// or a test in one, `DocsTableTests/everyDocHasARow()`, as xcodebuild's
/// `-only-testing` and `swift test --filter` both take it.
struct UnitTestSelection: Equatable, Sendable {
    /// The app's suites (SecondChanceTests).
    var app: [String] = []
    /// Each local package's suites, by package (`WrappKit`).
    var packages: [String: [String]] = [:]
    /// sc's own suites (Tools/sc).
    var tool: [String] = []

    /// Where each of `names` is declared, under the repo at `root`. A suite
    /// declared in more than one place runs in each.
    static func locate(_ names: [String], root: URL, packages: [String], integrationSuites: [String]) throws -> UnitTestSelection {
        var selection = UnitTestSelection()
        let packageFolders = packages.map { ($0, "Packages/\($0)/Tests") }
        for name in names {
            let suite = String(name.split(separator: "/", maxSplits: 1).first ?? "")
            guard !integrationSuites.contains(suite) else {
                throw SCError("\(suite) is an integration suite, which sc test unit doesn't run.",
                              hints: ["Run it with sc test integration --source <source>."])
            }
            var found = false
            if declares(suite, under: root.appendingPathComponent("SecondChanceTests")) {
                selection.app.append(name)
                found = true
            }
            for (package, folder) in packageFolders where declares(suite, under: root.appendingPathComponent(folder)) {
                selection.packages[package, default: []].append(name)
                found = true
            }
            if declares(suite, under: root.appendingPathComponent("Tools/sc/Tests")) {
                selection.tool.append(name)
                found = true
            }
            guard found else {
                var hints = ["A suite is named by its type, as declared in a test file: DocsTableTests, or DocsTableTests/aTest()."]
                if Catalog.game(slug: suite) != nil { hints.insert("To test the game \(suite): sc test integration \(suite)", at: 0) }
                throw SCError("No unit suite called \(suite).", hints: hints)
            }
        }
        return selection
    }

    /// Whether a Swift file under `folder` declares a type called `suite`: a
    /// line starting with the declaration, after any attributes and
    /// modifiers, so a name in a string or a comment doesn't count.
    static func declares(_ suite: String, under folder: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
        let pattern = #"^[ \t]*(?:@\w+(?:\([^)\n]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final|nonisolated)\s+)*"#
            + #"(?:struct|class|enum|actor|extension)\s+"# + NSRegularExpression.escapedPattern(for: suite) + #"\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return false }
        for case let file as URL in walker where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return true }
        }
        return false
    }
}
