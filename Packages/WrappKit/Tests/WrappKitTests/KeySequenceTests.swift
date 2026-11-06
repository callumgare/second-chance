//
//  KeySequenceTests.swift
//  WrappKitTests
//
//  The key notation (docs/wrappfile.md#key-sequences): parsed, refused,
//  written back in canonical form, and its key names kept in step with
//  the in-process helpers' key_names.m.

import Foundation
import Testing
@testable import KeyNotation
@testable import WrappFormat

@Suite("Key sequences")
struct KeySequenceTests {
    typealias Step = KeySequence.Step

    @Test("Each example parses to its steps", arguments: [
        ("f12:hold=5s", [Step(key: "f12", action: .hold(milliseconds: 5000))]),
        ("escape:hold=5s", [Step(key: "escape", action: .hold(milliseconds: 5000))]),
        ("up return*2", [Step(key: "up"), Step(key: "return", action: .presses(2))]),
        ("cmd+q", [Step(modifiers: [.cmd], key: "q")]),
        ("cmd+s", [Step(modifiers: [.cmd], key: "s")]),
        ("ctrl+alt+delete", [Step(modifiers: [.ctrl, .alt], key: "delete")]),
        ("shift+tab", [Step(modifiers: [.shift], key: "tab")]),
        ("a:hold=500ms", [Step(key: "a", action: .hold(milliseconds: 500))]),
        ("space:hold=1.5s", [Step(key: "space", action: .hold(milliseconds: 1500))]),
        ("escape wait=1s return", [Step(key: "escape"), Step(key: "return", waitMilliseconds: 1000)]),
        ("up up wait=0 return", [Step(key: "up"), Step(key: "up"), Step(key: "return", waitMilliseconds: 0)]),
        ("a wait=250ms b*2", [Step(key: "a"), Step(key: "b", action: .presses(2), waitMilliseconds: 250)]),
        ("gap=300ms up return", [Step(key: "up"), Step(key: "return")]),
        ("= wait=0s =", [Step(key: "="), Step(key: "=", waitMilliseconds: 0)]),
    ])
    func parses(_ text: String, _ steps: [Step]) throws {
        #expect(try KeySequence(parsing: text).steps == steps)
    }

    @Test("gap= is read first, and each duration as written", arguments: [
        ("gap=300ms up", 300),
        ("gap=0 up", 0),
        ("gap=1.5s up up", 1500),
        ("gap=30s up up", 30000),
    ])
    func gap(_ text: String, _ milliseconds: Int) throws {
        #expect(try KeySequence(parsing: text).gapMilliseconds == milliseconds)
    }

    @Test("Aliases and the long modifier names are read as their short forms")
    func aliases() throws {
        let keys = try KeySequence(parsing: "command+esc control+option+enter opt+backspace Escape F5")
        #expect(keys.canonical(defaultGapMilliseconds: 0)
            == "cmd+escape wait=0ms ctrl+alt+return wait=0ms alt+delete wait=0ms escape wait=0ms f5")
    }

    @Test("Modifiers come out in the Mac's order, once each")
    func modifierOrder() throws {
        #expect(try KeySequence(parsing: "cmd+shift+cmd+ctrl+x").canonical(defaultGapMilliseconds: 300) == "ctrl+shift+cmd+x")
    }

    @Test("The canonical form says every hold's length and every wait, at the presser's gap", arguments: [
        // A single press or hold has no waits.
        ("f12:hold=5s", 2500, "f12:hold=5000ms"),
        ("escape:hold=5s", 300, "escape:hold=5000ms"),
        ("cmd+q", 2500, "cmd+q"),
        ("return*1", 300, "return"),
        ("A", 300, "A"),
        (":", 300, ":"),
        ("::hold=2s", 300, "::hold=2000ms"),
        ("+", 300, "+"),
        ("shift++", 300, "shift++"),
        // Each presser's own gap between steps, and between a step's presses.
        ("up return*2", 2500, "up wait=2500ms return wait=2500ms return"),
        ("up return*2", 300, "up wait=300ms return wait=300ms return"),
        ("  up   down ", 300, "up wait=300ms down"),
        ("+*3", 300, "+ wait=300ms + wait=300ms +"),
        ("**2", 300, "* wait=300ms *"),
        ("escape escape:hold=5s", 2500, "escape wait=2500ms escape:hold=5000ms"),
        // A wait= in place of the gap there; wait=0 at once.
        ("escape wait=1s return", 2500, "escape wait=1000ms return"),
        ("escape wait=0 escape", 300, "escape wait=0ms escape"),
        ("up up wait=0 return", 2500, "up wait=2500ms up wait=0ms return"),
        ("up*2 wait=100ms return*2", 300, "up wait=300ms up wait=100ms return wait=300ms return"),
        // gap= in place of the presser's, and a wait= over that.
        ("gap=300ms up up up return", 2500, "up wait=300ms up wait=300ms up wait=300ms return"),
        ("gap=0 up*3", 300, "up wait=0ms up wait=0ms up"),
        ("gap=1s up wait=2s return", 300, "up wait=2000ms return"),
        ("gap=1.5s escape", 300, "escape"),
    ])
    func canonical(_ text: String, _ gap: Int, _ expected: String) throws {
        let keys = try KeySequence(parsing: text)
        #expect(keys.canonical(defaultGapMilliseconds: gap) == expected)
        // The canonical form is notation, and reads back as the same presses,
        // whatever gap reads it.
        let again = try KeySequence(parsing: expected)
        #expect(again.canonical(defaultGapMilliseconds: 99) == expected)
        #expect(again.presses() == keys.presses(defaultGapMilliseconds: gap))
    }

    @Test("The notation as written, tidied, reads back as itself", arguments: [
        ("gap=0.3s up wait=1s return*2", "gap=300ms up wait=1000ms return*2"),
        ("command+S wait=0 esc:hold=2s", "cmd+S wait=0ms escape:hold=2000ms"),
        ("return*1", "return"),
    ])
    func notation(_ text: String, _ expected: String) throws {
        let keys = try KeySequence(parsing: text)
        #expect(keys.notation == expected)
        #expect(try KeySequence(parsing: expected) == keys)
    }

    @Test("A sequence with no default gap leaves the presser to choose, but for waits and gap=")
    func pressesWithoutDefault() throws {
        let gaps = try KeySequence(parsing: "up*2 wait=0 return down").presses().map(\.gapMilliseconds)
        #expect(gaps == [nil, nil, 0, nil])
        #expect(try KeySequence(parsing: "gap=50ms up*2 wait=0 return").presses().map(\.gapMilliseconds) == [nil, 50, 0])
    }

    @Test("Refused, naming the bad part", arguments: [
        ("", "no keys"),
        ("   ", "no keys"),
        ("escapee", "escapee isn't a key"),
        ("hyper+q", "hyper isn't a modifier"),
        ("return*0", "*0"),
        ("escape:hold=5", "5 isn't a duration"),
        ("escape:hold=fast", "fast isn't a duration"),
        ("escape:hold=", "hold= needs a duration"),
        ("escape:hold=0ms", "0ms isn't a duration"),
        ("escape:hold=31s", "at most 30s"),
        ("return*2:hold=1s", "not both"),
        ("f12:hold", "says how long"),
        ("return:hold=1s*2", "not both"),
        ("return:hold=2s*2", "not both"),
        ("cmd+", "no key after the last +"),
        ("cmd++q", "an empty part"),
        ("*2", "no key before its suffix"),
        (":hold", "no key before its suffix"),
        ("escape:held", "a hold is written"),
        ("q+cmd", "cmd is a modifier"),
        ("return*101", "at most 100"),
        // Waits and gaps.
        ("wait=1s escape", "wait=1s: a wait goes between two steps, not before the first"),
        ("escape wait=1s", "wait=1s: a wait goes between two steps, not after the last"),
        ("gap=1s escape wait=1s", "wait=1s: a wait goes between two steps, not after the last"),
        ("escape wait=1s wait=2s return", "wait=1s wait=2s: two waits in a row"),
        ("escape gap=1s return", "gap=1s: gap= comes first"),
        ("gap=1s gap=2s escape", "gap=2s: the gap is given once"),
        ("gap=1s", "gap=1s: no keys"),
        ("wait=1s", "wait=1s: no keys"),
        ("gap=1s wait=0", "gap=1s wait=0: no keys"),
        ("escape wait=fast return", "fast isn't a duration"),
        ("escape wait= return", "wait= needs a duration"),
        ("escape wait=5 return", "5 isn't a duration"),
        ("escape wait=-1s return", "-1s isn't a duration"),
        ("escape wait=31s return", "wait=31s: a wait is at most 30s"),
        ("gap=30001ms escape", "gap=30001ms: a gap is at most 30s"),
        ("gap=soon escape", "soon isn't a duration"),
        ("escape wait return", "wait: a wait says how long"),
        ("gap escape", "gap: a gap says how long"),
        ("escape cmd+wait=1s return", "cmd+wait=1s: a wait takes no modifier"),
        ("escape wait=1s*2 return", "wait=1s*2: a wait is only how long"),
        ("escape wait=1s:hold=2s return", "wait=1s:hold=2s: a wait is only how long"),
        ("shift+gap=1s escape", "shift+gap=1s: a gap takes no modifier"),
    ])
    func refused(_ text: String, _ naming: String) {
        #expect {
            _ = try KeySequence(parsing: text)
        } throws: { error in
            "\(error)".contains(naming)
        }
    }
}

@Suite("Quit keys")
struct QuitKeySequenceTests {
    func launch(_ options: [String: String]) -> RecordedLaunch {
        RecordedLaunch(program: "wine:C:/game.exe", options: options)
    }

    @Test("Quit keys are pressed as written: a bare key once, a held one held")
    func quitKey() throws {
        #expect(try launch(["wine.quit-key": "f12"]).quitKeySequence()?.notation == "f12")
        #expect(try launch(["wine.quit-key": "f12:hold=5s"]).quitKeySequence()?.notation == "f12:hold=5000ms")
        #expect(try launch(["wine.quit-key": "escape escape return"]).quitKeySequence()?.notation == "escape escape return")
        #expect(try launch([:]).quitKeySequence() == nil)
    }

    @Test("Confirm keys are read beside a quit key, as written, and not without one")
    func confirmKey() throws {
        let icy = launch(["wine.quit-key": "escape", "wine.quit-confirm-key": "escape:hold=5s"])
        #expect(try icy.quitKeySequence()?.notation == "escape")
        #expect(try icy.quitConfirmKeySequence()?.notation == "escape:hold=5000ms")
        #expect(try launch(["wine.quit-key": "escape", "wine.quit-confirm-key": "escape"]).quitConfirmKeySequence()?.notation == "escape")
        #expect(try launch(["wine.quit-confirm-key": "escape"]).quitConfirmKeySequence() == nil)
    }
}

@Suite("Key names")
struct KeyNamesTests {
    /// The helpers' key_names.m, whose table KeySequence mirrors.
    static let keyNamesSource: String? = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/wine/InProcessHelpers/key_names.m")
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// The `@"name": @N` keys of one of key_names.m's dictionaries.
    static func dictionaryKeys(_ name: String, in source: String) -> Set<String> {
        guard let start = source.range(of: "\(name) = @{") else { return [] }
        let body = source[start.upperBound...].prefix { $0 != "}" }
        let pattern = /@"((?:[^"\\]|\\.)*)":\s*@\d+/
        return Set(body.matches(of: pattern).map { String($0.1).replacingOccurrences(of: "\\\\", with: "\\")
                .replacingOccurrences(of: "\\\"", with: "\"") })
    }

    /// One of key_names.m's string constants, `name = @"…"`.
    static func stringConstant(_ name: String, in source: String) throws -> Set<String> {
        guard let match = source.firstMatch(of: try Regex("\(name) = @\"((?:[^\"\\\\]|\\\\.)*)\"")),
              let text = match.output[1].substring else { return [] }
        let unescaped = String(text).replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\\"", with: "\"")
        return Set(unescaped.map(String.init))
    }

    @Test("KeySequence knows exactly the named keys key_names.m does")
    func namedKeys() throws {
        let source = try #require(Self.keyNamesSource)
        let named = Self.dictionaryKeys("named", in: source)
        #expect(!named.isEmpty)
        #expect(named == KeySequence.namedKeys)
        for (alias, name) in KeySequence.aliases {
            #expect(named.contains(alias) && named.contains(name))
        }
    }

    @Test("KeySequence knows exactly the characters key_names.m types")
    func characters() throws {
        let source = try #require(Self.keyNamesSource)
        let plain = Self.dictionaryKeys("plain", in: source).subtracting([" "])
        #expect(!plain.isEmpty)
        #expect(plain == KeySequence.characters)
        #expect(try Self.stringConstant("shifted", in: source) == KeySequence.shiftedCharacters)
    }
}
