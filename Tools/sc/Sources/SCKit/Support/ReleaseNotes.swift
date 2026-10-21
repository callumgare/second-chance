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
    ///
    /// Its output is streamed, so `activity` hears each thing it does as it
    /// does it, and `log` keeps every line of the stream.
    static func rewrite(
        notes: String, commits: String, prompt: String, model: String?, effort: String?, cwd: URL,
        log: LogSink, activity: @escaping @Sendable (String) -> Void
    ) async throws -> Rewrite {
        let input = """
        \(prompt)

        ## Generated notes

        \(notes)

        ## Commit messages

        \(commits)
        """
        var args = [
            "-p", "--output-format", "stream-json", "--verbose", "--json-schema", schema,
            "--tools", "Bash,Read,Grep,Glob",
            "--allowedTools", "Bash(git show:*)", "Bash(git log:*)", "Bash(git diff:*)", "Read(./**)", "Grep", "Glob",
            "--permission-mode", "dontAsk",
            "--strict-mcp-config", "--no-session-persistence",
        ]
        if let model { args += ["--model", model] }
        if let effort { args += ["--effort", effort] }
        let final = FinalReply()
        let status = try await Proc.stream("claude", args, cwd: cwd, input: input) { line in
            await log.line(line)
            switch StreamEvent(line: line) {
            case .activity(let text): activity(text)
            case .result(let reply): final.set(reply)
            case nil: final.other(line)
            }
        }
        let reply = final.reply
        guard status == 0, let reply, reply.is_error != true, let rewrite = reply.structured_output else {
            let detail = reply?.result ?? final.otherLines.joined(separator: "\n")
            throw SCError("Claude Code couldn't rewrite the notes (exit \(status)).",
                          hints: [detail.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        guard !rewrite.sections.isEmpty || !rewrite.internalChanges.isEmpty else {
            throw SCError("Claude Code returned no notes.")
        }
        return rewrite
    }

    /// The `result` line that ends Claude Code's stream.
    struct Reply: Decodable {
        let is_error: Bool?
        let result: String?
        let structured_output: Rewrite?
    }

    /// One line of `claude -p --output-format stream-json`, as far as sc
    /// cares: what it's doing, or how it ended. Everything else (its set-up,
    /// tool results, rate limits) is nil.
    enum StreamEvent {
        case activity(String)
        case result(Reply)

        init?(line: String) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { return nil }
            switch type {
            case "result":
                guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
                self = .result(reply)
            case "assistant":
                let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                // A turn can make several calls at once; the last says what it's waiting on.
                guard let text = content.compactMap(Self.describe).last else { return nil }
                self = .activity(text)
            default:
                return nil
            }
        }

        private static func describe(_ block: [String: Any]) -> String? {
            switch block["type"] as? String {
            case "thinking", "text": return "Thinking"
            case "tool_use":
                let input = block["input"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case "Bash": return (input["command"] as? String).map { "Running \(oneLine($0))" }
                case "Read": return (input["file_path"] as? String).map { "Reading \(URL(fileURLWithPath: $0).lastPathComponent)" }
                case "Grep": return (input["pattern"] as? String).map { "Searching for \(oneLine($0))" }
                case "Glob": return (input["pattern"] as? String).map { "Looking for \(oneLine($0))" }
                case "StructuredOutput": return "Writing the notes"
                case let name?: return "Using \(name)"
                case nil: return nil
                }
            default: return nil
            }
        }

        /// A command or pattern short enough for a spinner line.
        private static func oneLine(_ text: String) -> String {
            let flat = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return flat.count > 60 ? String(flat.prefix(59)) + "…" : flat
        }
    }

    /// The stream's result, and the lines that weren't events (stderr), for
    /// saying why it failed when there's no result.
    private final class FinalReply: @unchecked Sendable {
        private let lock = NSLock()
        private var _reply: Reply?
        private var _other: [String] = []

        func set(_ reply: Reply) { lock.withLock { _reply = reply } }
        func other(_ line: String) {
            lock.withLock {
                _other.append(line)
                if _other.count > 20 { _other.removeFirst() }
            }
        }
        var reply: Reply? { lock.withLock { _reply } }
        var otherLines: [String] { lock.withLock { _other } }
    }
}
