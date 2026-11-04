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
/// - `${…}` substitutes a reference (`${const.install-dir}`,
///   `${self.data.patches[input.id].url}`): brackets, not a nested `${…}`,
///   for a key worked out from a value. `$$` is a `$`.
/// - `INPUT`, `CONST`, `VAR` and `SET` declare and assign values, with `=`
///   spaced or not; `INPUT`s are only before the first `FROM` or at a
///   function's top.
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
        /// Where in `text` a quote began partway through the word
        /// (`${a}="b"`), which a condition splits.
        var quoteStart: Int?
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
        var quoteStart: Int?
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
                if !started { quoted = true } else if quoteStart == nil { quoteStart = current.count }
                started = true
            } else if character == " " || character == "\t" {
                if started { words.append(RawWord(text: current, quoted: quoted, quoteStart: quoteStart)) }
                current = ""
                quoted = false
                quoteStart = nil
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if inQuotes { throw WrappfileError(line: line, message: "a quote isn't closed") }
        if started { words.append(RawWord(text: current, quoted: quoted, quoteStart: quoteStart)) }
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

    /// A word, each `${…}` in it checked to be a reference.
    static func word(_ raw: RawWord, line: Int) throws(WrappfileError) -> Word {
        let parts = try parts(of: raw.text, line: line)
        for case .substitution(let inner) in parts {
            do {
                _ = try Reference.parse(inner)
            } catch {
                throw WrappfileError(line: line, message: error.message)
            }
        }
        return Word(raw: raw.text, parts: parts, quoted: raw.quoted)
    }

    /// The keywords that declare or assign a value.
    static var declarations: Set<String> { InstructionSpec.declarations }

    // MARK: - Structure

    struct Parser {
        var lines: [Line]
        var index = 0

        init(lines: [Line]) { self.lines = lines }

        mutating func file() throws(WrappfileError) -> Wrappfile {
            var file = Wrappfile()
            while index < lines.count {
                let line = lines[index]
                let keyword = line.words[0].text.uppercased()
                switch keyword {
                case "ARG":
                    throw WrappfileError(line: line.number, message: "ARG is gone: INPUT declares a value from outside, CONST a fixed one")
                case "INPUT", "CONST", "VAR":
                    index += 1
                    file.globals.append(try instruction(line))
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
                                         message: "\(line.words[0].text) comes before the first FROM; only INPUT, CONST, VAR and FUNCTION can")
                }
            }
            return file
        }

        /// `FROM <stage> [AS <name>]`, or a module's stage, named with a flag
        /// as Docker's `FROM --platform=` is: `FROM --module=wine@10 prefix`.
        func fromLine(_ line: Line) throws(WrappfileError) -> (StageSource, String?) {
            var words = line.words.dropFirst().map(\.text)
            var module: String?
            if let first = words.first, first.lowercased().hasPrefix("--module=") {
                module = String(first.dropFirst("--module=".count)).lowercased()
                words.removeFirst()
            }
            guard words.count == 1 || (words.count == 3 && words[1].uppercased() == "AS") else {
                throw WrappfileError(line: line.number, message: "FROM is FROM [--module=<module>[@<version>]] <stage> [AS <name>]")
            }
            let name = words.count == 3 ? words[2] : nil
            // Stage and module names, as Docker's stage names, whatever their case.
            let from = words[0].lowercased()
            if let module {
                guard !module.isEmpty else { throw WrappfileError(line: line.number, message: "FROM --module= names a module") }
                let at = module.firstIndex(of: "@")
                return (.module(id: at.map { String(module[..<$0]) } ?? module,
                                constraint: at.map { String(module[module.index(after: $0)...]) },
                                stage: from), name)
            }
            if from.contains("/") {
                throw WrappfileError(line: line.number, message: "FROM \(words[0]): a module's stage is written FROM --module=<module>[@<version>] <stage> now")
            }
            if from == "scratch" { return (.scratch, name) }
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
                case "ARG":
                    throw WrappfileError(line: line.number, message: "ARG is gone: INPUT declares a value from outside, CONST a fixed one")
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

        /// `<a> = <b>` or `<a> != <b>`, spaced or not, each side a `${…}` or
        /// a quoted string.
        func parseCondition(_ words: [RawWord], line: Int) throws(WrappfileError) -> Condition {
            let usage = "a condition is <a> = <b> or <a> != <b>, each a ${…} or a quoted string: IF ${platform.arch} = \"arm64\""
            // Split unquoted words at the operator, outside any ${…}.
            var tokens: [RawWord] = []
            for raw in words {
                guard !raw.quoted else {
                    tokens.append(raw)
                    continue
                }
                var current = ""
                var currentStart = 0
                var position = 0
                var depth = 0
                var characters = Array(raw.text)[...]
                func quotedFrom(_ start: Int) -> Bool { raw.quoteStart.map { $0 >= start } ?? false }
                while let character = characters.popFirst() {
                    position += 1
                    if character == "{", current.last == "$" { depth += 1 }
                    if character == "}", depth > 0 { depth -= 1 }
                    if depth == 0, character == "!" || character == "=" {
                        if !current.isEmpty { tokens.append(RawWord(text: current, quoted: quotedFrom(currentStart))) }
                        current = ""
                        if character == "!" {
                            guard characters.popFirst() == "=" else { throw WrappfileError(line: line, message: usage) }
                            tokens.append(RawWord(text: "!=", quoted: false))
                        } else {
                            tokens.append(RawWord(text: "=", quoted: false))
                        }
                        currentStart = position + (character == "!" ? 1 : 0)
                        if character == "!" { position += 1 }
                        continue
                    }
                    current.append(character)
                }
                if !current.isEmpty { tokens.append(RawWord(text: current, quoted: quotedFrom(currentStart))) }
            }
            guard tokens.count == 3, !tokens[1].quoted, let comparison = Condition.Comparison(rawValue: tokens[1].text) else {
                throw WrappfileError(line: line, message: usage)
            }
            let sides = [tokens[0], tokens[2]]
            for side in sides where !side.quoted && !(side.text.hasPrefix("${") && side.text.hasSuffix("}")) {
                throw WrappfileError(line: line, message: "\(side.text) in a condition is neither a ${…} nor a quoted string")
            }
            return Condition(left: try word(sides[0], line: line), comparison: comparison, right: try word(sides[1], line: line))
        }

        func instruction(_ line: Line) throws(WrappfileError) -> Instruction {
            var options: [InstructionOption] = []
            var arguments: [Word] = []
            // A program's arguments are its own, `--` or not: only before the
            // program are words options. Elsewhere options go anywhere
            // (`STEAM.INSTALL game --into=…`).
            let keyword = line.words[0].text.uppercased()
            if WrappfileParser.declarations.contains(keyword) { return try declaration(line, keyword: keyword) }
            let runsAProgram = keyword == "RUN" || keyword.hasSuffix(".RUN")
            var words = Array(line.words.dropFirst())[...]
            while let raw = words.popFirst() {
                if !runsAProgram || arguments.isEmpty, !raw.quoted, raw.text.hasPrefix("--"), raw.text.count > 2 {
                    let body = raw.text.dropFirst(2)
                    if body == "env", let value = words.first, value.text.contains("=") {
                        // `--env NAME=<value>`, as Docker writes it.
                        words.removeFirst()
                        options.append(InstructionOption(name: "env", value: try word(value, line: line.number)))
                    } else if let equals = body.firstIndex(of: "=") {
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

        /// `INPUT <name> [--default=<value>] [--secret]`, or `CONST`, `VAR`
        /// or `SET` `<name> [= <value>]`, `=` spaced or not: an instruction
        /// whose arguments are the name and the value.
        func declaration(_ line: Line, keyword: String) throws(WrappfileError) -> Instruction {
            var options: [InstructionOption] = []
            var rest: [RawWord] = []
            for raw in line.words.dropFirst() {
                if keyword == "INPUT", !raw.quoted, raw.text.hasPrefix("--") {
                    let body = raw.text.dropFirst(2)
                    if let equals = body.firstIndex(of: "=") {
                        let value = RawWord(text: String(body[body.index(after: equals)...]), quoted: false)
                        options.append(InstructionOption(name: String(body[..<equals]), value: try word(value, line: line.number)))
                    } else {
                        options.append(InstructionOption(name: String(body), value: nil))
                    }
                } else {
                    rest.append(raw)
                }
            }
            // name, =, value as written in one, two or three words.
            var parts: [RawWord] = []
            for raw in rest {
                if !raw.quoted, raw.text != "=", let equals = raw.text.firstIndex(of: "="), parts.isEmpty {
                    parts.append(RawWord(text: String(raw.text[..<equals]), quoted: false))
                    parts.append(RawWord(text: "=", quoted: false))
                    let after = String(raw.text[raw.text.index(after: equals)...])
                    if !after.isEmpty { parts.append(RawWord(text: after, quoted: false)) }
                } else if !raw.quoted, raw.text.hasPrefix("="), raw.text.count > 1, parts.count == 1 {
                    parts.append(RawWord(text: "=", quoted: false))
                    parts.append(RawWord(text: String(raw.text.dropFirst()), quoted: false))
                } else {
                    parts.append(raw)
                }
            }
            let usage = keyword == "INPUT" ? "INPUT is INPUT <name> [--default=<value>] [--secret]"
                : "\(keyword) is \(keyword) <name>\(keyword == "VAR" ? " [= <value>]" : " = <value>")"
            guard let name = parts.first, !name.quoted, !name.text.isEmpty else {
                throw WrappfileError(line: line.number, message: usage)
            }
            var arguments = [Word(raw: name.text, parts: [.text(name.text)])]
            switch parts.count {
            case 1 where keyword == "INPUT" || keyword == "VAR":
                break
            case 3 where keyword != "INPUT" && parts[1].text == "=" && !parts[1].quoted:
                arguments.append(try word(parts[2], line: line.number))
            default:
                throw WrappfileError(line: line.number, message: usage)
            }
            return Instruction(keyword: keyword, options: options, arguments: arguments, line: line.number)
        }
    }
}
