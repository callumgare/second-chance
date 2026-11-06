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
        ("f12:hold", [Step(key: "f12", action: .hold(milliseconds: nil))]),
        ("escape:hold=5s", [Step(key: "escape", action: .hold(milliseconds: 5000))]),
        ("up return*2", [Step(key: "up"), Step(key: "return", action: .presses(2))]),
        ("cmd+q", [Step(modifiers: [.cmd], key: "q")]),
        ("cmd+s", [Step(modifiers: [.cmd], key: "s")]),
        ("ctrl+alt+delete", [Step(modifiers: [.ctrl, .alt], key: "delete")]),
        ("shift+tab", [Step(modifiers: [.shift], key: "tab")]),
        ("a:hold=500ms", [Step(key: "a", action: .hold(milliseconds: 500))]),
        ("space:hold=1.5s", [Step(key: "space", action: .hold(milliseconds: 1500))]),
    ])
    func parses(_ text: String, _ steps: [Step]) throws {
        #expect(try KeySequence(parsing: text).steps == steps)
    }

    @Test("Aliases and the long modifier names are read as their short forms")
    func aliases() throws {
        let keys = try KeySequence(parsing: "command+esc control+option+enter opt+backspace Escape F5")
        #expect(keys.canonical == "cmd+escape ctrl+alt+return alt+delete escape f5")
    }

    @Test("Modifiers come out in the Mac's order, once each")
    func modifierOrder() throws {
        #expect(try KeySequence(parsing: "cmd+shift+cmd+ctrl+x").canonical == "ctrl+shift+cmd+x")
    }

    @Test("The canonical form says every hold's length", arguments: [
        ("f12:hold", "f12:hold=5000ms"),
        ("escape:hold=5s", "escape:hold=5000ms"),
        ("up return*2", "up return*2"),
        ("return*1", "return"),
        ("cmd+q", "cmd+q"),
        ("  up   down ", "up down"),
        ("+", "+"),
        ("shift++", "shift++"),
        ("+*3", "+*3"),
        ("**2", "**2"),
        (":", ":"),
        ("::hold=2s", "::hold=2000ms"),
        ("A", "A"),
    ])
    func canonical(_ text: String, _ expected: String) throws {
        let keys = try KeySequence(parsing: text)
        #expect(keys.canonical == expected)
        // And the canonical form reads back as the same keys.
        #expect(try KeySequence(parsing: keys.canonical).canonical == expected)
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
        ("return*2:hold", "not both"),
        ("return:hold*2", "not both"),
        ("return:hold=2s*2", "not both"),
        ("cmd+", "no key after the last +"),
        ("cmd++q", "an empty part"),
        ("*2", "no key before its suffix"),
        (":hold", "no key before its suffix"),
        ("escape:held", "a hold is written"),
        ("q+cmd", "cmd is a modifier"),
        ("return*101", "at most 100"),
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
        #expect(try launch(["wine.quit-key": "f12"]).quitKeySequence()?.canonical == "f12")
        #expect(try launch(["wine.quit-key": "f12:hold"]).quitKeySequence()?.canonical == "f12:hold=5000ms")
        #expect(try launch(["wine.quit-key": "escape escape return"]).quitKeySequence()?.canonical == "escape escape return")
        #expect(try launch([:]).quitKeySequence() == nil)
    }

    @Test("Confirm keys are read beside a quit key, as written, and not without one")
    func confirmKey() throws {
        let icy = launch(["wine.quit-key": "escape", "wine.quit-confirm-key": "escape:hold"])
        #expect(try icy.quitKeySequence()?.canonical == "escape")
        #expect(try icy.quitConfirmKeySequence()?.canonical == "escape:hold=5000ms")
        #expect(try launch(["wine.quit-key": "escape", "wine.quit-confirm-key": "escape"]).quitConfirmKeySequence()?.canonical == "escape")
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
