import Foundation

/// Turning the notes cog generates from commit messages into notes players
/// can read, by asking Claude Code (docs/releasing.md#release-notes).
enum ReleaseNotes {
    /// What Claude Code is asked for. sc lays out the Markdown itself, so the
    /// notes' shape doesn't depend on how the model formats them.
    struct Rewrite: Decodable, Equatable {
        struct Section: Decodable, Equatable {
            let heading: String
            let items: [String]
        }
        let sections: [Section]
        let internalChanges: [String]
    }

    static let headings = ["New", "Improved", "Fixed"]
    static let internalSummary = "Behind the scenes"

    static let schema = """
    {"type":"object","additionalProperties":false,"required":["sections","internalChanges"],"properties":{\
    "sections":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["heading","items"],"properties":{\
    "heading":{"type":"string","enum":["New","Improved","Fixed"]},\
    "items":{"type":"array","items":{"type":"string"}}}}},\
    "internalChanges":{"type":"array","items":{"type":"string"}}}}
    """

    /// The notes as Markdown: the user-facing sections in a fixed order, then
    /// the internal changes in a collapsed `<details>` block.
    static func markdown(_ rewrite: Rewrite) -> String {
        var blocks: [String] = []
        for heading in headings {
            let items = rewrite.sections.filter { $0.heading == heading }.flatMap(\.items).map(bulletText).filter { !$0.isEmpty }
            guard !items.isEmpty else { continue }
            blocks.append("### \(heading)\n\n" + items.map { "- \($0)" }.joined(separator: "\n"))
        }
        let internalItems = rewrite.internalChanges.map(bulletText).filter { !$0.isEmpty }
        if !internalItems.isEmpty {
            // GitHub only renders Markdown inside <details> after a blank line.
            blocks.append("<details>\n<summary>\(internalSummary)</summary>\n\n"
                          + internalItems.map { "- \($0)" }.joined(separator: "\n")
                          + "\n\n</details>")
        }
        return blocks.joined(separator: "\n\n")
    }

    /// The notes without their `<details>` blocks, for Sparkle's update
    /// window, which renders Markdown but not HTML. Says so when nothing
    /// user-facing is left.
    static func forUpdateWindow(_ notes: String) -> String {
        var kept: [String] = []
        var depth = 0
        for line in notes.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("<details") { depth += 1; continue }
            if trimmed.hasPrefix("</details>") { depth = max(0, depth - 1); continue }
            if depth == 0 { kept.append(line) }
        }
        let text = kept.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Behind-the-scenes improvements only — nothing you'll notice." : text
    }

    /// A model sometimes adds its own bullet marker; sc adds one already.
    private static func bulletText(_ item: String) -> String {
        var text = item.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["- ", "* ", "• "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Ask Claude Code to rewrite `notes`, with the commit messages behind
    /// them for context. When a message isn't enough it can look at the
    /// change itself, but only read: git's read commands and the repo's files
    /// are allowed, and `dontAsk` refuses everything else instead of asking.
    static func rewrite(notes: String, commits: String, prompt: String, cwd: URL) async throws -> Rewrite {
        let input = """
        \(prompt)

        ## Generated notes

        \(notes)

        ## Commit messages

        \(commits)
        """
        let result = try await Proc.collect("claude", [
            "-p", "--output-format", "json", "--json-schema", schema,
            "--tools", "Bash,Read,Grep,Glob",
            "--allowedTools", "Bash(git show:*)", "Bash(git log:*)", "Bash(git diff:*)", "Read(./**)", "Grep", "Glob",
            "--permission-mode", "dontAsk",
            "--strict-mcp-config", "--no-session-persistence",
        ], cwd: cwd, input: input)
        struct Reply: Decodable {
            let is_error: Bool?
            let result: String?
            let structured_output: Rewrite?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: Data(result.output.utf8))
        guard result.succeeded, let reply, reply.is_error != true, let rewrite = reply.structured_output else {
            let detail = reply?.result ?? (result.error.isEmpty ? result.output : result.error)
            throw SCError("Claude Code couldn't rewrite the notes (exit \(result.status)).",
                          hints: [detail.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        guard !rewrite.sections.isEmpty || !rewrite.internalChanges.isEmpty else {
            throw SCError("Claude Code returned no notes.")
        }
        return rewrite
    }
}
