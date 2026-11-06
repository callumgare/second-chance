//
//  KeySequence.swift
//  KeyNotation
//
//  Keys to press, as people write them: steps separated by spaces, done in
//  turn; keys pressed together joined with `+`, modifiers first (`cmd+s`);
//  `*N` to press a step N times (`return*2`), `:hold=<duration>` to hold it
//  down that long, repeating as a held Mac key does (`escape:hold=5s`): a
//  hold always says how long, as nothing can end one early. `wait=<duration>`
//  between two steps is the time between those two (`escape wait=1s
//  return`), and `gap=<duration>` first the time between every two
//  (`gap=300ms up up return`); otherwise whoever presses them leaves its own.
//  A launch's quit keys (`--wine.quit-key`), `sc puppet do … key` and a
//  scenario's `{ key: … }` all read it here (docs/wrappfile.md#key-sequences).
//
//  The in-process helpers read the `canonical` form, every press and every
//  wait between them explicit, with one small parser of their own
//  (key_names.m's helperKeySteps):
//  docs/wine-in-process-helpers.md#the-canonical-key-sequence.

import Foundation

/// A sequence of keys to press, parsed from the notation.
nonisolated public struct KeySequence: Sendable, Equatable, CustomStringConvertible {
    public var steps: [Step]
    /// `gap=<duration>`, written first: the time between every two steps
    /// (and between the presses of a step pressed several times) in place
    /// of the presser's usual gap. Nil when the sequence gives none.
    public var gapMilliseconds: Int?

    public init(steps: [Step], gapMilliseconds: Int? = nil) {
        self.steps = steps
        self.gapMilliseconds = gapMilliseconds
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
        /// `*N`: down and up N times, the sequence's gap between.
        case presses(Int)
        /// `:hold=<duration>`: held down that long, repeating as a held Mac
        /// key does.
        case hold(milliseconds: Int)
    }

    /// One step: keys pressed together, what's done with them, and any
    /// `wait=` written before it.
    public struct Step: Sendable, Equatable, CustomStringConvertible {
        public var modifiers: [Modifier]
        /// The key's name, as key_names.m knows it: a named key in its
        /// canonical spelling (`escape`, not `esc`), or the character it types.
        public var key: String
        public var action: Action
        /// `wait=<duration>` before it: the time from the step before's
        /// release to this one's press, in place of the sequence's gap. Nil
        /// when none is written; never on the first step.
        public var waitMilliseconds: Int?

        public init(modifiers: [Modifier] = [], key: String, action: Action = .press, waitMilliseconds: Int? = nil) {
            self.modifiers = modifiers
            self.key = key
            self.action = action
            self.waitMilliseconds = waitMilliseconds
        }

        /// How many times it's pressed: 1 for a hold.
        public var pressCount: Int {
            if case .presses(let count) = action { return count }
            return 1
        }

        /// How long it's held, in ms; nil when it's pressed.
        public var holdMilliseconds: Int? {
            if case .hold(let milliseconds) = action { return milliseconds }
            return nil
        }

        /// The keys pressed together, as the notation writes them: `cmd+s`.
        public var chord: String {
            (modifiers.map(\.rawValue) + [key]).joined(separator: "+")
        }

        /// The step as the notation writes it, its wait aside: `cmd+s`,
        /// `return*2`, `escape:hold=5000ms`.
        public var notation: String {
            switch action {
            case .press: chord
            case .presses(let count): count == 1 ? chord : "\(chord)*\(count)"
            case .hold(let milliseconds): "\(chord):hold=\(milliseconds)ms"
            }
        }

        public var description: String { notation }
    }

    /// One press or hold, as it's done: a step pressed several times is
    /// that many of these.
    public struct Press: Sendable, Equatable {
        /// What's pressed: its action `.press` or `.hold`, and no wait.
        public var step: Step
        /// From the press before's release to this one's press, in ms. Nil
        /// for the first, and for one at the presser's usual gap when it
        /// has none to give (a scenario, which waits for the screen).
        public var gapMilliseconds: Int?
    }

    /// The longest hold, wait or gap it takes.
    public static let longestHoldMilliseconds = 30000
    /// The most presses `*N` takes.
    public static let mostPresses = 100

    /// Each press in turn, and the time before it: a `wait=` where one is
    /// written, else the sequence's `gap=`, else the presser's
    /// `defaultGapMilliseconds`.
    public func presses(defaultGapMilliseconds: Int? = nil) -> [Press] {
        let gap = gapMilliseconds ?? defaultGapMilliseconds
        var presses: [Press] = []
        for step in steps {
            let pressed = Step(modifiers: step.modifiers, key: step.key,
                               action: step.holdMilliseconds.map { .hold(milliseconds: $0) } ?? .press)
            for press in 0..<step.pressCount {
                let before = presses.isEmpty ? nil : press == 0 ? (step.waitMilliseconds ?? gap) : gap
                presses.append(Press(step: pressed, gapMilliseconds: before))
            }
        }
        return presses
    }

    /// What the helpers read: every press in turn, separated by a
    /// `wait=<n>ms` saying exactly how long from one's release to the next's
    /// press, which is `defaultGapMilliseconds` unless the sequence says
    /// otherwise (`gap=`, `wait=`). Every hold says how long, a step pressed
    /// several times is written out press by press, and there's no `gap=`, so
    /// the helpers need no defaults of their own. It is notation, and reads
    /// back as the same presses: `escape wait=2500ms escape:hold=5000ms`.
    public func canonical(defaultGapMilliseconds: Int) -> String {
        presses(defaultGapMilliseconds: defaultGapMilliseconds).map { press in
            press.gapMilliseconds.map { "wait=\($0)ms \(press.step.notation)" } ?? press.step.notation
        }.joined(separator: " ")
    }

    /// The sequence as the notation writes it, tidied: `gap=` first if it's
    /// given, the long names short, durations in ms, `return*1` as `return`.
    public var notation: String {
        let words = steps.flatMap { step in
            (step.waitMilliseconds.map { ["wait=\($0)ms"] } ?? []) + [step.notation]
        }
        return ((gapMilliseconds.map { ["gap=\($0)ms"] } ?? []) + words).joined(separator: " ")
    }

    public var description: String { notation }

    // MARK: - Parsing

    /// Why the notation couldn't be read, naming the part that's wrong.
    public struct ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Parse the notation: `up return*2`, `cmd+q`, `f12:hold=2s`,
    /// `escape wait=1s return`, `gap=300ms up up return`.
    public init(parsing text: String) throws(ParseError) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.contains(where: { Self.timing($0) == nil }) else {
            throw ParseError(words.isEmpty ? "no keys: write at least one, such as escape or cmd+q"
                : "\(words.joined(separator: " ")): no keys, only time between them; write at least one, such as escape")
        }
        var steps: [Step] = []
        var gap: Int?
        var wait: (word: String, milliseconds: Int)?
        for (index, word) in words.enumerated() {
            switch Self.timing(word) {
            case "gap":
                guard index == 0 else {
                    throw ParseError(gap == nil ? "\(word): gap= comes first, before the keys"
                        : "\(word): the gap is given once, first")
                }
                gap = try Self.duration(of: word, named: "gap")
            case "wait":
                if let wait { throw ParseError("\(wait.word) \(word): two waits in a row; write one") }
                guard !steps.isEmpty else { throw ParseError("\(word): a wait goes between two steps, not before the first") }
                wait = (word, try Self.duration(of: word, named: "wait"))
            default:
                var step = try Self.step(word)
                step.waitMilliseconds = wait?.milliseconds
                wait = nil
                steps.append(step)
            }
        }
        if let wait { throw ParseError("\(wait.word): a wait goes between two steps, not after the last") }
        self.steps = steps
        self.gapMilliseconds = gap
    }

    /// `gap` or `wait` for a word that's one of them, or tries to be one
    /// (`cmd+wait=1s`, `wait`); nil for a step.
    static func timing(_ word: String) -> String? {
        for name in ["gap", "wait"] where word == name || word.hasPrefix("\(name)=") || word.contains("+\(name)=") {
            return name
        }
        return nil
    }

    /// The duration of a `gap=` or `wait=` word, 0 to 30 s.
    static func duration(of word: String, named name: String) throws(ParseError) -> Int {
        guard word.hasPrefix("\(name)=") else {
            throw ParseError(word == name ? "\(word): a \(name) says how long, such as \(name)=1s"
                : "\(word): a \(name) takes no modifier; it's \(name)=<duration> alone")
        }
        let duration = String(word.dropFirst(name.count + 1))
        if duration.contains("*") || duration.contains(":") {
            throw ParseError("\(word): a \(name) is only how long; *N and :hold are for keys")
        }
        guard let milliseconds = duration == "0" ? 0 : Self.milliseconds(duration, allowingNone: true) else {
            throw ParseError("\(word): \(duration.isEmpty ? "\(name)= needs" : "\(duration) isn't") a duration, such as 0, 300ms or 1.5s")
        }
        guard milliseconds <= longestHoldMilliseconds else {
            throw ParseError("\(word): a \(name) is at most \(longestHoldMilliseconds / 1000)s")
        }
        return milliseconds
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
                // Nothing can end a hold early, so it says how long.
                throw ParseError("\(word): a hold says how long, such as \(chord):hold=2s")
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
            action = count == 1 ? .press : .presses(count)
        } else if let colon = word.lastIndex(of: ":"), colon > word.startIndex, word.index(after: colon) < word.endIndex {
            throw ParseError("\(word): a hold is written :hold=<duration>, such as :hold=2s")
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
    /// unless it's one and more than none (or none, `allowingNone`).
    static func milliseconds(_ text: String, allowingNone: Bool = false) -> Int? {
        let (number, scale): (Substring, Double) = text.hasSuffix("ms") ? (text.dropLast(2), 1)
            : text.hasSuffix("s") ? (text.dropLast(1), 1000) : ("", 0)
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let value = Double(number) else { return nil }
        let milliseconds = Int((value * scale).rounded())
        return milliseconds >= (allowingNone ? 0 : 1) ? milliseconds : nil
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
