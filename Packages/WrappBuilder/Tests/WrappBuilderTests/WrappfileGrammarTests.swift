import Foundation
import Testing
@testable import WrappBuilder

/// VS Code's Wrappfile highlighting (`Tools/vscode-wrappfile`) names the
/// core's instructions itself, so one added to the core is added there too.
struct WrappfileGrammarTests {
    @Test func theGrammarKnowsEveryCoreInstruction() throws {
        let url = repoRoot.appendingPathComponent("Tools/vscode-wrappfile/syntaxes/wrappfile.tmLanguage.json")
        let grammar = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let repository = try #require(grammar["repository"] as? [String: [String: Any]])
        // `(?i)^\s*(RUN|COPY|…)(?=\s|$)`: the first group's alternatives,
        // matched whatever their case
        let written = try #require(repository["instruction"]?["match"] as? String)
        #expect(written.hasPrefix("(?i)"))
        let match = String(written.dropFirst("(?i)".count))
        let open = try #require(match.range(of: "("))
        let close = try #require(match.range(of: ")", range: open.upperBound..<match.endIndex))
        let named = Set(match[open.upperBound..<close.lowerBound].split(separator: "|").map(String.init))
        // ARG and USE have rules of their own, which name what follows them
        #expect(repository["arg"] != nil && repository["use"] != nil)
        #expect(named.union(["ARG", "USE"]) == Set(InstructionSpec.core.keys))
    }
}
