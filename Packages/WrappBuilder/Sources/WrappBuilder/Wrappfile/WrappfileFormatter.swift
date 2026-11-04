//
//  WrappfileFormatter.swift
//  WrappBuilder
//
//  A Wrappfile kept whole, comments and blank lines included, and written
//  back in the one style (`wrapp-builder fmt`).

import Foundation

/// A Wrappfile as written, losing nothing: every comment, blank line and
/// continued line kept with its place, as Swift's own syntax tree keeps
/// trivia. Planning reads `WrappfileParser`'s tree instead and ignores all
/// of this; formatting and migrating rewrite a file from this one.
public nonisolated struct WrappfileSyntaxTree: Sendable, Equatable {
    public var nodes: [Node]

    public enum Node: Sendable, Equatable {
        case blank
        /// A line that is a comment and nothing else, `#` and all.
        case comment(String)
        /// An instruction: its first line, then each line it continues on.
        case instruction([PhysicalLine])
    }

    /// One line of an instruction: its code, with the `\` that continues
    /// it, and a comment after the code, with the spaces before it.
    public struct PhysicalLine: Sendable, Equatable {
        public var code: String
        public var comment: String?
        public var gap: String

        /// Whether it ends in `\`, continuing on the next line.
        public var continues: Bool { code.hasSuffix("\\") }
    }

    /// The tree of `text`, which is only split into lines here: what's
    /// wrong in it is the parser's to say.
    public init(_ text: String) {
        var nodes: [Node] = []
        var pending: [PhysicalLine] = []
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for raw in lines {
            let physical = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let (code, gap, comment) = Self.split(physical)
            if pending.isEmpty {
                if code.isEmpty {
                    nodes.append(comment.map(Node.comment) ?? .blank)
                    continue
                }
            }
            pending.append(PhysicalLine(code: code, comment: comment, gap: gap))
            if !code.hasSuffix("\\") {
                nodes.append(.instruction(pending))
                pending = []
            }
        }
        if !pending.isEmpty { nodes.append(.instruction(pending)) }
        self.nodes = nodes
    }

    /// A line's code, trimmed, the spaces after it, and its comment: `#` at
    /// the start of a word, outside quotes, as the parser reads one.
    static func split(_ line: String) -> (code: String, gap: String, comment: String?) {
        var inQuotes = false
        var previous: Character = " "
        for index in line.indices {
            let character = line[index]
            if character == "\"" { inQuotes.toggle() }
            if character == "#", !inQuotes, previous == " " || previous == "\t" {
                let before = line[..<index]
                let code = before.trimmingCharacters(in: .whitespaces)
                let gap = String(before.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
                return (code, code.isEmpty ? "" : gap, String(line[index...]).trimmingCharacters(in: .whitespaces))
            }
            previous = character
        }
        return (line.trimmingCharacters(in: .whitespaces), "", nil)
    }
}

/// Writes a Wrappfile in the one style (docs/wrappfile.md#style):
///
/// - instructions in upper case;
/// - two spaces of indent per block (`FUNCTION`, `IF`, `LAYER-HINT`);
/// - a continued line indented four spaces past its instruction;
/// - one blank line between stages, and never two in a row;
/// - comments kept where they are, with their text unchanged.
///
/// With `migrate`, the syntax that has changed is rewritten first
/// (`WrappfileMigration`), so a bundle written for an older Second Chance
/// reads as this one's.
public nonisolated enum WrappfileFormatter {
    public static func format(_ text: String, migrate: Bool = false) -> String {
        var tree = WrappfileSyntaxTree(text)
        if migrate { tree = WrappfileMigration.migrate(tree) }
        var output: [String] = []
        var depth = 0
        var lastWasBlank = true
        func emit(_ line: String) {
            output.append(line)
            lastWasBlank = line.isEmpty
        }
        for (index, node) in tree.nodes.enumerated() {
            switch node {
            case .blank:
                if !lastWasBlank { emit("") }
            case .comment(let text):
                // A stage's comments come before its FROM, with a blank line
                // before them all.
                if depth == 0, !lastWasBlank, startsStage(after: index, in: tree.nodes), !(output.last?.hasPrefix("#") ?? true) {
                    emit("")
                }
                emit(String(repeating: "  ", count: depth) + text)
            case .instruction(let lines):
                let keyword = Self.keyword(lines[0].code)
                switch keyword {
                case "FROM": depth = 0
                case "END", "ELSE", "ELSE IF": depth = max(0, depth - 1)
                default: break
                }
                if keyword == "FROM", !lastWasBlank, !(output.last?.hasPrefix("#") ?? false) {
                    emit("")
                }
                for (number, line) in lines.enumerated() {
                    let indent = String(repeating: "  ", count: depth) + (number == 0 ? "" : "    ")
                    let code = number == 0 ? Self.upperCasingKeyword(line.code) : line.code
                    emit(indent + code + (line.comment.map { (line.gap.isEmpty ? " " : line.gap) + $0 } ?? ""))
                }
                switch keyword {
                case "FUNCTION", "IF", "ELSE", "ELSE IF", "LAYER-HINT", "LAYER", "SIGNAL": depth += 1
                default: break
                }
            }
        }
        while output.last == "" { output.removeLast() }
        return output.joined(separator: "\n") + "\n"
    }

    /// Whether the comments from `index` lead to a `FROM`.
    static func startsStage(after index: Int, in nodes: [WrappfileSyntaxTree.Node]) -> Bool {
        for node in nodes[index...] {
            switch node {
            case .comment: continue
            case .instruction(let lines): return keyword(lines[0].code) == "FROM"
            case .blank: return false
            }
        }
        return false
    }

    /// An instruction's keyword, in upper case: `ELSE IF` as one.
    static func keyword(_ code: String) -> String {
        let words = code.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard let first = words.first?.uppercased() else { return "" }
        if first == "ELSE", words.count > 1, words[1].uppercased() == "IF" { return "ELSE IF" }
        return first
    }

    /// `code` with its keyword in upper case (`wine.mount` as `WINE.MOUNT`,
    /// `else if` as `ELSE IF`), the rest as written.
    static func upperCasingKeyword(_ code: String) -> String {
        guard let space = code.firstIndex(of: " ") else { return code.uppercased() }
        let first = code[..<space].uppercased()
        var rest = String(code[space...])
        if first == "ELSE", rest.dropFirst().prefix(3).uppercased() == "IF " || rest.dropFirst().uppercased() == "IF" {
            rest = " IF" + rest.dropFirst(3)
        }
        return first + rest
    }

    /// Whether `text` is already as `format` writes it.
    public static func isFormatted(_ text: String, migrate: Bool = false) -> Bool { format(text, migrate: migrate) == text }
}

/// The syntax that has changed, rewritten as it's written now
/// (`wrapp-builder fmt --migrate`): a word at a time, in an instruction's
/// code, never its comments.
public nonisolated enum WrappfileMigration {
    public static func migrate(_ tree: WrappfileSyntaxTree) -> WrappfileSyntaxTree {
        var migrated = tree
        migrated.nodes = tree.nodes.map { node in
            guard case .instruction(var lines) = node else { return node }
            for index in lines.indices {
                lines[index].code = migrate(code: lines[index].code, first: index == 0)
            }
            return .instruction(lines)
        }
        return migrated
    }

    static func migrate(code: String, first: Bool) -> String {
        var code = code
        // A module's file: module:<id>/<path> as module:<id>:/<path>.
        code = code.replacingOccurrences(of: #"module:([a-z0-9]+(?:-[a-z0-9]+)*)/"#, with: "module:$1:/", options: .regularExpression)
        // EDIT's --must-exist, which is about the keys.
        code = code.replacingOccurrences(of: #"(^|\s)--must-exist(?=\s|$|\\)"#, with: "$1--keys-must-exist", options: .regularExpression)
        guard first else { return code }
        let keyword = WrappfileFormatter.keyword(code)
        if keyword == "FROM" {
            // A module's stage: FROM <id>@<v>/<stage> as FROM --module=<id>@<v> <stage>.
            code = code.replacingOccurrences(of: #"^(\S+)\s+([a-z0-9@._-]+(?:/[a-z0-9._-]+)*)/([a-z0-9._-]+)(?=\s|$)"#,
                                             with: "$1 --module=$2 $3", options: [.regularExpression, .caseInsensitive])
        } else if keyword == "ICON" {
            // The app's icon is APP's.
            code = code.replacingOccurrences(of: #"^\S+\s+(\S+)"#, with: "APP --icon=$1", options: .regularExpression)
        }
        return code
    }
}
