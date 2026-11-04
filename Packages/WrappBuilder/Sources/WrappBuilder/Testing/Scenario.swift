//
//  Scenario.swift
//  WrappBuilder
//
//  How a test drives a program, as a module describes it: a set of
//  handlers, each waiting for a needle's tag, rather than a list of steps.

import Foundation

/// A scenario (`<module>/scenarios/<name>.yaml`): handlers that each wait
/// for a tag and say what to do when it shows, a goal and a time limit, and
/// parameters a bundle can set (docs/testing.md#scenarios). It names tags,
/// never files, so an edition with another title screen adds a needle and
/// leaves the scenario alone.
public nonisolated struct Scenario: Sendable, Equatable {
    /// `nancy-drew/quit-from-menu`.
    public let id: String
    public let goal: String
    /// Seconds the handlers have to reach the goal.
    public let timeout: Double
    /// The scenario's parameters, with the bundle's values over its own.
    public let parameters: [String: String]
    public let handlers: [Handler]

    public struct Handler: Sendable, Equatable {
        public let id: String
        /// The tag it waits for, or `blank` for a screen with nothing on it.
        public let when: String
        /// A parameter that must be true for it to run.
        public let condition: String?
        /// Whether it runs only once.
        public let once: Bool
        /// Seconds before it acts again on a screen it acted on that hasn't
        /// changed; nil acts again at once.
        public let retryAfter: Double?
        /// Seconds after which, when its needle isn't found, it clicks where
        /// it was last found: a menu drawn over by the program's own cursor.
        public let repeatWhereLastSeen: Double?
        public let actions: [Action]

        /// Whether its condition holds with `parameters`.
        public func applies(with parameters: [String: String]) -> Bool {
            guard let condition else { return true }
            return parameters[condition] == "true"
        }
    }

    public enum Action: Sendable, Equatable {
        /// Click the needle's click point.
        case click
        /// Click a point of the window, as fractions of it.
        case clickAt(Needle.Point)
        /// Run a named check the test runner offers (`menu`).
        case check(String)
        /// The click before it should end the program: nothing else runs
        /// once it has.
        case expectEnd
        /// Ask the program to quit, as its app's Quit (⌘Q) does, and expect
        /// it to end: for a program with nothing to click to quit.
        case quit
    }

    /// The scenario at `file`, with `overrides` (the bundle's parameters)
    /// over its own.
    public static func load(id: String, file: URL, overrides: [String: String] = [:]) throws -> Scenario {
        let raw: Raw
        do {
            raw = try Manifest.decodeKebab(Raw.self, from: YAML12.load(String(contentsOf: file, encoding: .utf8)))
        } catch {
            throw ScenarioError(description: "\(id): \(error)")
        }
        var parameters = (raw.parameters ?? [:]).mapValues(\.text)
        for (name, value) in overrides {
            guard parameters[name] != nil else {
                throw ScenarioError(description: "\(id) has no parameter called \(name)")
            }
            parameters[name] = value
        }
        let handlers = try raw.handlers.map { handler throws(ScenarioError) -> Handler in
            func number(_ value: Manifest.TestValue?) throws(ScenarioError) -> Double? {
                guard let value else { return nil }
                let text = try substitute(value.text, parameters: parameters, in: "\(id) \(handler.id)")
                guard let number = Double(text) else {
                    throw ScenarioError(description: "\(id) \(handler.id): \(text) isn't a number of seconds")
                }
                return number
            }
            if let condition = handler.if, parameters[condition] == nil {
                throw ScenarioError(description: "\(id) \(handler.id): no parameter called \(condition)")
            }
            return Handler(id: handler.id, when: handler.when, condition: handler.if, once: handler.once ?? false,
                           retryAfter: try number(handler.retryAfter), repeatWhereLastSeen: try number(handler.repeatWhereLastSeen),
                           actions: handler.do.map(\.action))
        }
        return Scenario(id: id, goal: raw.goal, timeout: raw.timeout, parameters: parameters, handlers: handlers)
    }

    static func substitute(_ text: String, parameters: [String: String], in place: String) throws(ScenarioError) -> String {
        guard text.hasPrefix("${"), text.hasSuffix("}") else { return text }
        let name = String(text.dropFirst(2).dropLast())
        guard let value = parameters[name] else { throw ScenarioError(description: "\(place): no parameter called \(name)") }
        return value
    }

    // MARK: - As written

    struct Raw: Decodable {
        let goal: String
        let timeout: Double
        let parameters: [String: Manifest.TestValue]?
        let handlers: [RawHandler]

        struct RawHandler: Decodable {
            let id: String
            let when: String
            let `if`: String?
            let once: Bool?
            let retryAfter: Manifest.TestValue?
            let repeatWhereLastSeen: Manifest.TestValue?
            let `do`: [RawAction]
        }

        /// `click`, `expect-end`, `quit`, `{ click: { x, y } }` or `{ check: menu }`.
        struct RawAction: Decodable {
            let action: Action

            init(from decoder: Decoder) throws {
                if let word = try? decoder.singleValueContainer().decode(String.self) {
                    switch word {
                    case "click": action = .click
                    case "expect-end": action = .expectEnd
                    case "quit": action = .quit
                    default:
                        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no action called \(word)"))
                    }
                    return
                }
                let keyed = try decoder.container(keyedBy: Update.AnyKey.self)
                if let key = Update.AnyKey(stringValue: "click"), keyed.contains(key) {
                    action = .clickAt(try keyed.decode(Needle.Point.self, forKey: key))
                } else if let key = Update.AnyKey(stringValue: "check"), keyed.contains(key) {
                    action = .check(try keyed.decode(String.self, forKey: key))
                } else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "an action is click, expect-end, { click: … } or { check: … }"))
                }
            }
        }
    }
}

public nonisolated struct ScenarioError: Error, CustomStringConvertible, Equatable {
    public let description: String

    public init(description: String) { self.description = description }
}

/// What a program's test is: its scenario, from the module that has it,
/// with the bundle's parameters, and the needles from its folders nearest
/// first. Generic: it knows bundles and modules, not any program.
public nonisolated struct ProgramTest: Sendable {
    public let scenario: Scenario
    public let needles: NeedleLibrary
    /// The window the program is expected to end up in (`tests.window`):
    /// `fullscreen`, `windowed`, or nil for whatever its wrapp gives it.
    public var window: String?

    /// The test of the bundle at `bundleFolder`, with modules in `modulesRoot`:
    /// the manifest's `tests.scenario` (`<module>/<name>`) and parameters.
    public static func load(bundleFolder: URL, modulesRoot: URL) throws -> ProgramTest {
        let manifest = try Manifest.decode(YAML12.load(String(contentsOf: bundleFolder.appendingPathComponent("manifest.yaml"), encoding: .utf8)))
        guard let tests = manifest.tests, let scenarioID = tests.scenario else {
            throw ScenarioError(description: "\(manifest.id) names no test scenario")
        }
        let parts = scenarioID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw ScenarioError(description: "\(manifest.id): \(scenarioID) isn't <module>/<scenario>") }
        let module = modulesRoot.appendingPathComponent(parts[0])
        let scenario = try Scenario.load(id: scenarioID, file: module.appendingPathComponent("scenarios/\(parts[1]).yaml"),
                                         overrides: (tests.parameters ?? [:]).mapValues(\.text))
        let needles = try NeedleLibrary.load([
            bundleFolder.appendingPathComponent("tests/needles"),
            module.appendingPathComponent("needles"),
        ])
        return ProgramTest(scenario: scenario, needles: needles, window: tests.window)
    }
}
