//
//  KeySequence.swift
//  KeyNotation
//
//  Keys to press, as people write them: steps separated by spaces, done in
//  turn; keys pressed together joined with `+`, modifiers first (`cmd+s`);
//  `*N` to press a step N times (`return*2`), `:hold` to hold it down for
//  the default time, repeating as a held Mac key does, or `:hold=<duration>`
//  for that long (`escape:hold=5s`). A launch's quit keys
//  (`--wine.quit-key`), `sc puppet do … key` and a scenario's `{ key: … }`
//  all read it here (docs/wrappfile.md#key-sequences).
//
//  The in-process helpers read the `canonical` form, every step explicit,
//  with one small parser of their own (key_names.m's helperKeySteps):
//  docs/wine-in-process-helpers.md#the-canonical-key-sequence.

import Foundation

/// A sequence of keys to press, parsed from the notation.
nonisolated public struct KeySequence: Sendable, Equatable, CustomStringConvertible {
    public var steps: [Step]

    public init(steps: [Step]) {
        self.steps = steps
    }

    /// A modifier held while a step's key is pressed, in the order the
    /// canonical form writes them (the Mac's: ⌃⌥⇧⌘).
    public enum Modifier: String, Sendable, CaseIterable, Comparable {
        case ctrl, alt, shift, cmd

        /// The names each is written as: its short form first, which docs use.
        public static let names: [String: Modifier] = [
            "ctrl": .ctrl, "control": .ctrl,
            "alt": .alt, "option": .alt, "opt": .alt,
            "shift": .shift,
            "cmd": .cmd, "command": .cmd,
        ]

        public static func < (lhs: Modifier, rhs: Modifier) -> Bool {
            (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
        }
    }

    /// What a step does with its keys.
    public enum Action: Sendable, Equatable {
        /// Down and up once, nothing written after the key.
        case press
        /// `*N`: down and up N times, the sequence's usual gap between.
        case presses(Int)
        /// `:hold` (nil: the default, `defaultHoldMilliseconds`) or
        /// `:hold=<duration>`: held down that long, repeating as a held Mac
        /// key does.
        case hold(milliseconds: Int?)
    }

    /// One step: keys pressed together, and what's done with them.
    public struct Step: Sendable, Equatable, CustomStringConvertible {
        public var modifiers: [Modifier]
        /// The key's name, as key_names.m knows it: a named key in its
        /// canonical spelling (`escape`, not `esc`), or the character it types.
        public var key: String
        public var action: Action

        public init(modifiers: [Modifier] = [], key: String, action: Action = .press) {
            self.modifiers = modifiers
            self.key = key
            self.action = action
        }

        /// A key alone with nothing written after it: what a quit key was
        /// before the notation had suffixes, which it still means for a
        /// launch (`RecordedLaunch.quitKeySequence`).
        public var isBare: Bool { modifiers.isEmpty && action == .press }

        /// How many times it's pressed: 1 for a hold.
        public var pressCount: Int {
            if case .presses(let count) = action { return count }
            return 1
        }

        /// How long it's held, in ms; nil when it's pressed.
        public var holdMilliseconds: Int? {
            if case .hold(let milliseconds) = action { return milliseconds ?? KeySequence.defaultHoldMilliseconds }
            return nil
        }

        /// The keys pressed together, as the notation writes them: `cmd+s`.
        public var chord: String {
            (modifiers.map(\.rawValue) + [key]).joined(separator: "+")
        }

        /// The step in canonical form: `cmd+s`, `return*2`, `escape:hold=5000ms`.
        public var canonical: String {
            switch action {
            case .press: chord
            case .presses(let count): count == 1 ? chord : "\(chord)*\(count)"
            case .hold: "\(chord):hold=\(holdMilliseconds ?? KeySequence.defaultHoldMilliseconds)ms"
            }
        }

        public var description: String { canonical }
    }

    /// How long `:hold` holds a key: long enough for a game that wants it
    /// held (Iji quits on F12 held for about a second), and for one that
    /// takes the key's repeats as presses to reach its Exit (Icy Tower's
    /// Escape, held from a game, reaches it in about 3 s).
    public static let defaultHoldMilliseconds = 5000
    /// The longest hold it takes.
    public static let longestHoldMilliseconds = 30000
    /// The most presses `*N` takes.
    public static let mostPresses = 100

    /// Every step in canonical form, separated by spaces: what the helpers
    /// read. Every hold says how long; a press count is written when over 1.
    public var canonical: String { steps.map(\.canonical).joined(separator: " ") }

    public var description: String { canonical }

    /// Whether it's a single key with nothing written after it.
    public var isSingleBareKey: Bool { steps.count == 1 && steps[0].isBare }

    // MARK: - Parsing

    /// Why the notation couldn't be read, naming the part that's wrong.
    public struct ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Parse the notation: `up return*2`, `cmd+q`, `f12:hold`, `escape:hold=5s`.
    public init(parsing text: String) throws(ParseError) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { throw ParseError("no keys: write at least one, such as escape or cmd+q") }
        var steps: [Step] = []
        for word in words { steps.append(try Self.step(word)) }
        self.steps = steps
    }

    /// One step: its chord, then any suffix.
    static func step(_ word: String) throws(ParseError) -> Step {
        var chord = word
        var action = Action.press
        if word.hasPrefix(":hold") || (word.hasPrefix("*") && word.count > 1 && word.dropFirst().allSatisfy(\.isNumber)) {
            throw ParseError("\(word): no key before its suffix")
        }
        if let colon = Self.holdSuffix(in: word) {
            chord = String(word[..<colon])
            let suffix = String(word[word.index(after: colon)...])
            if suffix == "hold" {
                action = .hold(milliseconds: nil)
            } else {
                let duration = String(suffix.dropFirst("hold=".count))
                if duration.contains("*") {
                    throw ParseError("\(word): a step is pressed several times (*N) or held (:hold), not both")
                }
                guard let milliseconds = Self.milliseconds(duration) else {
                    throw ParseError("\(word): \(duration.isEmpty ? "hold= needs" : "\(duration) isn't") a duration, such as 500ms, 2s or 1.5s")
                }
                guard milliseconds <= longestHoldMilliseconds else {
                    throw ParseError("\(word): a key is held at most \(longestHoldMilliseconds / 1000)s")
                }
                action = .hold(milliseconds: milliseconds)
            }
            if Self.countSuffix(in: chord) != nil {
                throw ParseError("\(word): a step is pressed several times (*N) or held (:hold), not both")
            }
        } else if let star = Self.countSuffix(in: word) {
            chord = String(word[..<star])
            let digits = String(word[word.index(after: star)...])
            guard let count = Int(digits), count >= 1 else {
                throw ParseError("\(word): *\(digits) presses it no times; write *1 or more, or leave the step out")
            }
            guard count <= mostPresses else { throw ParseError("\(word): a step is pressed at most \(mostPresses) times") }
            if chord.hasSuffix(":hold") || chord.contains(":hold=") {
                throw ParseError("\(word): a step is pressed several times (*N) or held (:hold), not both")
            }
            action = .presses(count)
        } else if let colon = word.lastIndex(of: ":"), colon > word.startIndex, word.index(after: colon) < word.endIndex {
            throw ParseError("\(word): a hold is written :hold or :hold=<duration>, such as :hold=2s")
        }
        var (modifiers, key) = try Self.chord(chord, in: word)
        guard let name = Self.keyName(key) else {
            throw ParseError("\(word): \(key) isn't a key; keys are named as escape, return, space, tab, up, f1, a, 1 or a punctuation character")
        }
        key = name
        modifiers = Array(Set(modifiers)).sorted()
        return Step(modifiers: modifiers, key: key, action: action)
    }

    /// Where a `:hold` or `:hold=…` suffix starts, if the word has one after a key.
    static func holdSuffix(in word: String) -> String.Index? {
        guard let range = word.range(of: ":hold", options: .backwards), range.lowerBound > word.startIndex else { return nil }
        let rest = word[range.upperBound...]
        guard rest.isEmpty || rest.hasPrefix("=") else { return nil }
        return range.lowerBound
    }

    /// Where a `*N` suffix starts, if the word ends in one after a key.
    static func countSuffix(in word: String) -> String.Index? {
        guard let star = word.lastIndex(of: "*"), star > word.startIndex else { return nil }
        let digits = word[word.index(after: star)...]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return star
    }

    /// A chord's modifiers and its key: `+` alone, or last after modifiers
    /// (`shift++`), is the plus key.
    static func chord(_ chord: String, in word: String) throws(ParseError) -> ([Modifier], String) {
        guard !chord.isEmpty else { throw ParseError("\(word): no key before its suffix") }
        var parts = chord.components(separatedBy: "+")
        if chord.hasSuffix("+") {
            // `+` itself, or `<mods>++`: the last part is the plus key.
            parts = chord == "+" ? ["+"] : Array(chord.dropLast(2).components(separatedBy: "+")) + ["+"]
            if chord != "+", !chord.hasSuffix("++") { throw ParseError("\(word): no key after the last +") }
        }
        let key = parts.removeLast()
        if Modifier.names[key.lowercased()] != nil, key.count > 1 {
            throw ParseError("\(word): \(key) is a modifier; a step ends with the key it presses, as cmd+q")
        }
        var modifiers: [Modifier] = []
        for part in parts {
            guard !part.isEmpty else { throw ParseError("\(word): an empty part between +s") }
            guard let modifier = Modifier.names[part.lowercased()] else {
                throw ParseError("\(word): \(part) isn't a modifier; they're cmd, ctrl, alt and shift, written before the key")
            }
            modifiers.append(modifier)
        }
        return (modifiers, key)
    }

    /// A duration as written, `500ms`, `2s` or `1.5s`, in whole ms; nil
    /// unless it's one and more than none.
    static func milliseconds(_ text: String) -> Int? {
        let (number, scale): (Substring, Double) = text.hasSuffix("ms") ? (text.dropLast(2), 1)
            : text.hasSuffix("s") ? (text.dropLast(1), 1000) : ("", 0)
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let value = Double(number) else { return nil }
        let milliseconds = Int((value * scale).rounded())
        return milliseconds >= 1 ? milliseconds : nil
    }

    // MARK: - Key names

    /// A key's canonical name, or nil when key_names.m can't press it: a
    /// named key in any case, or a single character it types.
    public static func keyName(_ written: String) -> String? {
        let lowered = written.lowercased()
        if let alias = aliases[lowered] { return alias }
        if namedKeys.contains(lowered) { return lowered }
        guard written.count == 1 else { return nil }
        if characters.contains(written) || shiftedCharacters.contains(written) { return written }
        if characters.contains(lowered) { return written }
        return nil
    }

    /// The named keys key_names.m knows (`helperKeyCode`'s `named`), aliases
    /// included. KeyNamesTests reads them out of key_names.m, so the two
    /// can't drift apart unnoticed.
    public static let namedKeys: Set<String> = [
        "return", "enter", "tab", "space", "delete", "backspace", "escape", "esc", "forwarddelete",
        "home", "end", "pageup", "pagedown", "left", "right", "down", "up",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    ]

    /// The other name each alias is written in canonical form as.
    public static let aliases: [String: String] = ["enter": "return", "esc": "escape", "backspace": "delete"]

    /// The characters key_names.m types without shift (`plain`, less the
    /// space, which is `space` in a sequence)...
    public static let characters: Set<String> = Set(
        "abcdefghijklmnopqrstuvwxyz1234567890-=[]\\;',./`".map(String.init))
    /// ...and with it (`shifted`), upper-case letters aside.
    public static let shiftedCharacters: Set<String> = Set("~!@#$%^&*()_+{}|:\"<>?".map(String.init))
}
