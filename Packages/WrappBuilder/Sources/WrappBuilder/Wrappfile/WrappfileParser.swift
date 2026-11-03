//
//  WrappfileParser.swift
//  WrappBuilder
//
//  Text to `Wrappfile`.

import Foundation

/// Reads a Wrappfile's text (docs/wrappfile.md has the grammar):
///
/// - One instruction a line; a line ending in `\` continues on the next,
///   and that is the only place `\` is special, so Windows paths and
///   registry keys are written as they are.
/// - `#` at the start of a word, outside quotes, starts a comment.
/// - Words are split on spaces; double quotes make one word of what's
///   between them, and `""` inside them is a quote.
/// - Options (`--name[=value]`) may be anywhere, except that for `RUN` (or
///   a module's `.RUN`) the first word that isn't one is the program, and
///   everything after it is the program's arguments.
/// - Keywords are case-insensitive, a module's name in an instruction
///   included (`WINE.MOUNT`, `wine.mount`), and kept in upper case. Stage
///   and function names are too, as Docker's stage names are, and kept in
///   lower case.
/// - `${…}` substitutes, and may nest (`${data.patches.${id}.url}`); `$$`
///   is a `$`.
public nonisolated enum WrappfileParser {
    public static func parse(_ text: String) throws(WrappfileError) -> Wrappfile {
        var parser = Parser(lines: try logicalLines(text))
        return try parser.file()
    }

    // MARK: - Lines and words

    struct Line {
        let number: Int
        let words: [RawWord]
    }

    /// A word as written: its text with quotes removed, and whether it
    /// starts with a quote (a quoted `"--x"` is an argument, not an option,
    /// while `--x="a b"` is an option).
    struct RawWord {
        let text: String
        let quoted: Bool
    }

    static func logicalLines(_ text: String) throws(WrappfileError) -> [Line] {
        var result: [Line] = []
        var pending = ""
        var start = 0
        for (index, physical) in text.components(separatedBy: "\n").enumerated() {
            let number = index + 1
            if pending.isEmpty { start = number }
            let trimmed = physical.hasSuffix("\r") ? String(physical.dropLast()) : physical
            let (content, continues) = try strippingComment(trimmed, line: number)
            pending += (pending.isEmpty ? "" : " ") + content
            if continues { continue }
            let words = try split(pending, line: start)
            if !words.isEmpty { result.append(Line(number: start, words: words)) }
            pending = ""
        }
        if !pending.isEmpty {
            let words = try split(pending, line: start)
            if !words.isEmpty { result.append(Line(number: start, words: words)) }
        }
        return result
    }

    /// The line without its comment, and whether it ends in `\` (outside
    /// quotes), continuing on the next.
    static func strippingComment(_ line: String, line number: Int) throws(WrappfileError) -> (String, Bool) {
        var inQuotes = false
        var previous: Character = " "
        var kept = ""
        for character in line {
            if character == "\"" { inQuotes.toggle() }
            if character == "#", !inQuotes, previous == " " || previous == "\t" { break }
            kept.append(character)
            previous = character
        }
        let trimmed = kept.trimmingCharacters(in: .whitespaces)
        if !inQuotes, trimmed.hasSuffix("\\") {
            return (String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces), true)
        }
        return (trimmed, false)
    }

    static func split(_ text: String, line: Int) throws(WrappfileError) -> [RawWord] {
        var words: [RawWord] = []
        var current = ""
        var quoted = false
        var inQuotes = false
        var started = false
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            if inQuotes {
                if character == "\"" {
                    if characters.first == "\"" {
                        current.append("\"")
                        characters.removeFirst()
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
                // Quoted from its start: an argument, whatever it says.
                if !started { quoted = true }
                started = true
            } else if character == " " || character == "\t" {
                if started { words.append(RawWord(text: current, quoted: quoted)) }
                current = ""
                quoted = false
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if inQuotes { throw WrappfileError(line: line, message: "a quote isn't closed") }
        if started { words.append(RawWord(text: current, quoted: quoted)) }
        return words
    }

    /// `text`'s literal text and `${…}` substitutions.
    static func parts(of text: String, line: Int) throws(WrappfileError) -> [Word.Part] {
        var parts: [Word.Part] = []
        var literal = ""
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            guard character == "$" else {
                literal.append(character)
                continue
            }
            if characters.first == "$" {
                characters.removeFirst()
                literal.append("$")
            } else if characters.first == "{" {
                characters.removeFirst()
                var depth = 1
                var inner = ""
                while let next = characters.popFirst() {
                    if next == "{", inner.last == "$" { depth += 1 }
                    if next == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    inner.append(next)
                }
                guard depth == 0, !inner.isEmpty else {
                    throw WrappfileError(line: line, message: "a ${ isn't closed, or is empty")
                }
                if !literal.isEmpty { parts.append(.text(literal)) }
                literal = ""
                parts.append(.substitution(inner))
            } else {
                literal.append("$")
            }
        }
        if !literal.isEmpty { parts.append(.text(literal)) }
        return parts
    }

    static func word(_ raw: RawWord, line: Int) throws(WrappfileError) -> Word {
        Word(raw: raw.text, parts: try parts(of: raw.text, line: line))
    }

    /// `name` or `name=value`, as an `ARG` declares it.
    static func argDeclaration(_ word: Word, line: Int) -> ArgDeclaration {
        guard let equals = word.raw.firstIndex(of: "=") else {
            return ArgDeclaration(name: word.raw, value: nil, line: line)
        }
        let value = String(word.raw[word.raw.index(after: equals)...])
        return ArgDeclaration(name: String(word.raw[..<equals]),
                              value: Word(raw: value, parts: (try? parts(of: value, line: line)) ?? [.text(value)]), line: line)
    }

    // MARK: - Structure

    struct Parser {
        var lines: [Line]
        var index = 0

        init(lines: [Line]) { self.lines = lines }

        mutating func file() throws(WrappfileError) -> Wrappfile {
            var file = Wrappfile()
            while index < lines.count {
                let line = lines[index]
                switch line.words[0].text.uppercased() {
                case "ARG" where file.stages.isEmpty:
                    index += 1
                    guard line.words.count == 2 else { throw WrappfileError(line: line.number, message: "ARG takes one name, with its value: ARG name=value") }
                    file.globalArgs.append(argDeclaration(try word(line.words[1], line: line.number), line: line.number))
                case "FUNCTION":
                    index += 1
                    guard line.words.count == 2 else { throw WrappfileError(line: line.number, message: "FUNCTION takes one name") }
                    let body = try steps(until: ["END"], in: "FUNCTION", openedAt: line.number).steps
                    index += 1  // END
                    file.functions.append(WrappfileFunction(name: line.words[1].text.lowercased(), body: body, line: line.number,
                                                            nameAsWritten: line.words[1].text))
                case "FROM":
                    index += 1
                    let (source, name) = try fromLine(line)
                    let body = try steps(until: ["FROM", "FUNCTION"], in: nil, topLevel: true).steps
                    file.stages.append(Stage(name: name?.lowercased(), from: source, body: body, line: line.number, nameAsWritten: name))
                default:
                    throw WrappfileError(line: line.number,
                                         message: "\(line.words[0].text) comes before the first FROM; only ARG and FUNCTION can")
                }
            }
            return file
        }

        func fromLine(_ line: Line) throws(WrappfileError) -> (StageSource, String?) {
            let words = line.words.map(\.text)
            guard words.count == 2 || (words.count == 4 && words[2].uppercased() == "AS") else {
                throw WrappfileError(line: line.number, message: "FROM is FROM <stage> [AS <name>]")
            }
            let name = words.count == 4 ? words[3] : nil
            // Stage and module names, as Docker's stage names, whatever their case.
            let from = words[1].lowercased()
            if from == "scratch" { return (.scratch, name) }
            if let slash = from.lastIndex(of: "/") {
                let module = String(from[..<slash])
                let stage = String(from[from.index(after: slash)...])
                let at = module.firstIndex(of: "@")
                return (.module(id: at.map { String(module[..<$0]) } ?? module,
                                constraint: at.map { String(module[module.index(after: $0)...]) },
                                stage: stage), name)
            }
            return (.stage(from), name)
        }

        /// Steps up to one of `terminators` (not consumed), or the end of
        /// the file. At the top level, `FROM` and `FUNCTION` end a stage.
        mutating func steps(until terminators: Set<String>, in block: String?, openedAt: Int = 0,
                            topLevel: Bool = false) throws(WrappfileError) -> (steps: [Step], end: Line?) {
            var collected: [Step] = []
            while index < lines.count {
                let line = lines[index]
                let keyword = line.words[0].text.uppercased()
                let elseIf = keyword == "ELSE" && line.words.count > 1 && line.words[1].text.uppercased() == "IF"
                if terminators.contains(keyword) || (elseIf && terminators.contains("ELSE IF")) {
                    return (collected, line)
                }
                index += 1
                switch keyword {
                case "IF":
                    collected.append(try conditional(first: line))
                case "LAYER":
                    let body = try steps(until: ["END"], in: "LAYER", openedAt: line.number).steps
                    index += 1
                    collected.append(.layer(body, line: line.number))
                case "END", "ELSE":
                    throw WrappfileError(line: line.number, message: "\(keyword) without an IF\(keyword == "END" ? ", LAYER or FUNCTION" : "") to close")
                case "FROM", "FUNCTION":
                    throw WrappfileError(line: line.number, message: "\(keyword) can't be inside \(block ?? "a stage")")
                default:
                    collected.append(.instruction(try instruction(line)))
                }
            }
            if let block, !topLevel {
                throw WrappfileError(line: openedAt, message: "\(block) has no END")
            }
            return (collected, nil)
        }

        mutating func conditional(first: Line) throws(WrappfileError) -> Step {
            var branches: [Step.Branch] = []
            var condition: Condition? = try parseCondition(Array(first.words.dropFirst()), line: first.number)
            var branchLine = first.number
            while true {
                let (body, end) = try steps(until: ["END", "ELSE", "ELSE IF"], in: "IF", openedAt: first.number)
                branches.append(Step.Branch(condition: condition, steps: body, line: branchLine))
                guard let end else { throw WrappfileError(line: first.number, message: "IF has no END") }
                index += 1
                if end.words[0].text.uppercased() == "END" { break }
                if condition == nil { throw WrappfileError(line: end.number, message: "nothing can follow ELSE but END") }
                branchLine = end.number
                if end.words.count > 1, end.words[1].text.uppercased() == "IF" {
                    condition = try parseCondition(Array(end.words.dropFirst(2)), line: end.number)
                } else if end.words.count == 1 {
                    condition = nil
                } else {
                    throw WrappfileError(line: end.number, message: "ELSE takes nothing, or IF and a condition")
                }
            }
            return .conditional(branches)
        }

        func parseCondition(_ words: [RawWord], line: Int) throws(WrappfileError) -> Condition {
            let texts = words.map(\.text)
            if texts.count == 3, texts[1] == "has" {
                return Condition(name: texts[0], comparison: .has, value: texts[2])
            }
            guard texts.count == 1 else {
                throw WrappfileError(line: line, message: "a condition is name=value, name>=value, name has value or a bare name")
            }
            let text = texts[0]
            for comparison in [Condition.Comparison.notEquals, .atLeast, .atMost, .equals, .greater, .less] {
                if let range = text.range(of: comparison.rawValue) {
                    let name = String(text[..<range.lowerBound])
                    let value = String(text[range.upperBound...])
                    guard !name.isEmpty, !value.isEmpty else { break }
                    return Condition(name: name, comparison: comparison, value: value)
                }
            }
            return Condition(name: text, comparison: nil, value: nil)
        }

        func instruction(_ line: Line) throws(WrappfileError) -> Instruction {
            var options: [InstructionOption] = []
            var arguments: [Word] = []
            // A program's arguments are its own, `--` or not: only before the
            // program are words options. Elsewhere options go anywhere
            // (`STEAM.INSTALL game --into=…`).
            let keyword = line.words[0].text.uppercased()
            let runsAProgram = keyword == "RUN" || keyword.hasSuffix(".RUN")
            for raw in line.words.dropFirst() {
                if !runsAProgram || arguments.isEmpty, !raw.quoted, raw.text.hasPrefix("--"), raw.text.count > 2 {
                    let body = raw.text.dropFirst(2)
                    if let equals = body.firstIndex(of: "=") {
                        let value = RawWord(text: String(body[body.index(after: equals)...]), quoted: false)
                        options.append(InstructionOption(name: String(body[..<equals]), value: try word(value, line: line.number)))
                    } else {
                        options.append(InstructionOption(name: String(body), value: nil))
                    }
                } else {
                    arguments.append(try word(raw, line: line.number))
                }
            }
            return Instruction(keyword: keyword, options: options, arguments: arguments, line: line.number)
        }
    }
}
