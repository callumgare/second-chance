//
//  PuppetRequest.swift
//  PuppetProtocol
//
//  What a client may ask the in-process helper (game-<pid>.sock) and the
//  wrapp (wrapp.sock), as the line each is sent as. One request per
//  connection: a line in, a reply out, starting `ok` or `error`. Points are
//  in the game window, in points from its top left — a capture's pixels
//  divided by its scale. Options are `name=value` words after the arguments.
//  docs/wine-in-process-helpers.md#puppet-control has the table.

import CoreGraphics
import Foundation
import KeyNotation

/// The helper's protocol version, as `hello` says it: 1 (no `hello`), 2
/// (`hello`, `windows`, `down`/`up`/`drag`, `key`, `type`, `focus`), 3
/// (`scroll`), 4 (`audio`), 5 (`key` takes a key sequence's step: `*N`,
/// `:hold=`, and `gap=`).
nonisolated public enum PuppetProtocolVersion {
    public static let current = 5
}

nonisolated public enum MouseButton: String, Sendable, CaseIterable {
    case left, right
}

/// Which way a scroll action turns the wheel.
nonisolated public enum ScrollDirection: String, Sendable, CaseIterable {
    case up, down, left, right
}

/// A request to the in-process helper, which answers for the game's window
/// from inside the game's process.
nonisolated public enum PuppetRequest: Sendable, Equatable {
    /// `ok version=<n> pid=<n> exe=<name> commands=<list>`.
    case hello
    /// The game window: its number, size, scale, fullscreen, focus and cursor.
    case state
    /// Every window the process has, a line each after `ok <n> windows`.
    case windows
    /// A PNG of the game window at `path`, or of `region` of it (in points),
    /// at `scale` pixels a point rather than the window's own.
    case capture(path: String, region: CGRect? = nil, scale: Double? = nil)
    /// A move, a pause for the game to see it, then the button held for
    /// `hold` ms (100), `count` times.
    case click(CGPoint, button: MouseButton? = nil, count: Int? = nil, hold: Int? = nil)
    case move(CGPoint)
    case down(CGPoint, button: MouseButton? = nil)
    case up(CGPoint, button: MouseButton? = nil)
    /// A press at `from`, `steps` moves (10) along the line, a release at `to`.
    case drag(from: CGPoint, to: CGPoint, steps: Int? = nil, hold: Int? = nil)
    /// A scroll wheel's turn at a point: `lines` down (negative: up), and
    /// `across` right (negative: left). Protocol 3.
    case scroll(CGPoint, lines: Int, across: Int? = nil)
    /// One step of a key sequence, in canonical form (`KeySequence.Step`):
    /// a key by its name (`escape`, `return`, `f5`, `a`), modifiers first
    /// (`cmd+s`), pressed and held `hold` ms (60); `*N` presses it N times,
    /// `gap` ms apart (300), and `:hold=<ms>ms` holds it, repeating as a
    /// held Mac key does (protocol 5). `keys(_:hold:)` makes these from
    /// what people write.
    case key(String, hold: Int? = nil, gap: Int? = nil)
    /// Each character as its key, shift where it needs it.
    case type(String)
    /// The app active and the game window key.
    case focus
    /// Hand activation to the app with this pid.
    case yield(pid: Int32)
    /// Quit as the app's Quit menu item does.
    case quit
    /// Listen for `seconds` (at most 60) to the samples the game hands Core
    /// Audio, and say how loud they were (`PuppetAudio`). A Wine game only.
    /// Protocol 4.
    case audio(seconds: Double)

    /// Its first word.
    public var verb: String {
        switch self {
        case .hello: "hello"
        case .state: "state"
        case .windows: "windows"
        case .capture: "capture"
        case .click: "click"
        case .move: "move"
        case .down: "down"
        case .up: "up"
        case .drag: "drag"
        case .scroll: "scroll"
        case .key: "key"
        case .type: "type"
        case .focus: "focus"
        case .yield: "yield"
        case .quit: "quit"
        case .audio: "audio"
        }
    }

    /// The line it's sent as, without its newline.
    public var line: String {
        var words = [verb]
        var options: [(String, String)] = []
        func point(_ p: CGPoint) { words += [Self.number(p.x), Self.number(p.y)] }
        func option(_ name: String, _ value: CustomStringConvertible?) {
            if let value { options.append((name, value.description)) }
        }
        switch self {
        case .hello, .state, .windows, .focus, .quit:
            break
        case let .capture(path, region, scale):
            words.append(path)
            option("region", region.map { [$0.minX, $0.minY, $0.width, $0.height].map(Self.number).joined(separator: ",") })
            option("scale", scale.map { String(format: "%.3f", $0) })
        case let .click(at, button, count, hold):
            point(at)
            option("button", button?.rawValue)
            option("count", count)
            option("hold", hold)
        case let .move(at):
            point(at)
        case let .down(at, button), let .up(at, button):
            point(at)
            option("button", button?.rawValue)
        case let .drag(from, to, steps, hold):
            point(from)
            point(to)
            option("steps", steps)
            option("hold", hold)
        case let .scroll(at, lines, across):
            point(at)
            words.append(String(lines))
            option("across", across)
        case let .key(step, hold, gap):
            words.append(step)
            option("hold", hold)
            option("gap", gap)
        case let .type(text):
            words.append(Self.encoded(text))
        case let .yield(pid):
            words.append(String(pid))
        case let .audio(seconds):
            words.append(Self.number(CGFloat(seconds)))
        }
        return (words + options.map { "\($0.0)=\($0.1)" }).joined(separator: " ")
    }

    /// A request from an action's words, as `sc puppet do` is given them:
    /// `click 120 340`, `key cmd+s`, `type hello there`, `scroll 400 300 -3`.
    /// Options a person gives apart (`--button`) are passed in. Throws, saying
    /// what's wrong, for an action it doesn't know or the wrong arguments.
    public static func action(_ words: [String], button: MouseButton? = nil, count: Int? = nil,
                              hold: Int? = nil) throws -> PuppetRequest {
        guard let verb = words.first else { throw PuppetProtocolError("Say what to do: \(actionVerbs.joined(separator: ", ")).") }
        let arguments = Array(words.dropFirst())
        func numbers(_ wanted: Int) throws -> [Double] {
            let values = arguments.compactMap(Double.init)
            guard arguments.count == wanted, values.count == wanted else {
                throw PuppetProtocolError("\(verb) takes \(wanted) numbers: \(usage[verb] ?? verb).")
            }
            return values
        }
        switch verb {
        case "click":
            let n = try numbers(2)
            return .click(CGPoint(x: n[0], y: n[1]), button: button, count: count, hold: hold)
        case "move":
            let n = try numbers(2)
            return .move(CGPoint(x: n[0], y: n[1]))
        case "down", "up":
            let n = try numbers(2)
            let at = CGPoint(x: n[0], y: n[1])
            return verb == "down" ? .down(at, button: button) : .up(at, button: button)
        case "drag":
            let n = try numbers(4)
            return .drag(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[3]), hold: hold)
        case "scroll":
            // A direction in words, not a sign: a command line takes `-3` for an option.
            let amount = arguments.count == 4 ? Int(arguments[3]) : 3
            guard arguments.count == 3 || arguments.count == 4, let x = Double(arguments[0]), let y = Double(arguments[1]),
                  let amount, amount > 0, let direction = ScrollDirection(rawValue: arguments[2]) else {
                throw PuppetProtocolError("scroll takes a point, a direction and whole lines: \(usage["scroll"] ?? "scroll").")
            }
            let at = CGPoint(x: x, y: y)
            switch direction {
            case .down: return .scroll(at, lines: amount)
            case .up: return .scroll(at, lines: -amount)
            case .right: return .scroll(at, lines: 0, across: amount)
            case .left: return .scroll(at, lines: 0, across: -amount)
            }
        case "key":
            let requests = try keys(arguments.joined(separator: " "), hold: hold)
            guard requests.count == 1, let request = requests.first else {
                throw PuppetProtocolError("key here takes one step; several are sent in turn with keys(_:): \(usage["key"] ?? "key").")
            }
            return request
        case "type":
            guard !arguments.isEmpty else { throw PuppetProtocolError("type takes the text: \(usage["type"] ?? "type").") }
            return .type(arguments.joined(separator: " "))
        case "focus":
            guard arguments.isEmpty else { throw PuppetProtocolError("focus takes nothing more.") }
            return .focus
        default:
            throw PuppetProtocolError("Unknown action \(verb): \(actionVerbs.joined(separator: ", ")).")
        }
    }

    /// The actions `action(_:)` knows, in the order they're told.
    public static let actionVerbs = ["click", "move", "drag", "down", "up", "scroll", "key", "type", "focus"]

    /// How each action is written.
    public static let usage: [String: String] = [
        "click": "click <x> <y>",
        "move": "move <x> <y>",
        "down": "down <x> <y>",
        "up": "up <x> <y>",
        "drag": "drag <x> <y> <x2> <y2>",
        "scroll": "scroll <x> <y> up|down|left|right [<lines>, 3 unless given]",
        "key": "key <keys>, as up return*2, cmd+s or escape:hold=2s",
        "type": "type <text>",
        "focus": "focus",
    ]

    /// The requests that press keys as people write them
    /// (docs/wrappfile.md#key-sequences): one `key` a step, in canonical
    /// form, to be sent in turn, `keyStepGap` apart. A press is held `hold`
    /// ms. Throws, naming the bad part, for keys the notation refuses.
    public static func keys(_ text: String, hold: Int? = nil) throws -> [PuppetRequest] {
        let sequence: KeySequence
        do {
            sequence = try KeySequence(parsing: text)
        } catch {
            throw PuppetProtocolError("\(error)")
        }
        return sequence.steps.map { .key($0.canonical, hold: hold) }
    }

    /// From one step's end to the next's start, as `keys(_:hold:)`'s
    /// requests are sent: as long as the helper leaves between presses of
    /// a step pressed several times.
    public static let keyStepGap: Duration = .milliseconds(300)

    /// How long to wait for its reply: a held key, or one pressed many
    /// times, takes that long before it's answered.
    public var timeout: TimeInterval {
        guard case let .key(text, hold, gap) = self, let step = try? KeySequence(parsing: text).steps.first else { return 45 }
        let pressing = Double(step.pressCount) * Double((hold ?? 60) + (gap ?? 300)) / 1000
        return 20 + max(Double(step.holdMilliseconds ?? 0) / 1000, pressing)
    }

    /// A region as people write it, `x,y,w,h` in points; nil unless it's four numbers.
    public static func region(_ text: String) -> CGRect? {
        let n = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
    }

    /// A coordinate as the helper reads it: whole numbers without a fraction.
    public static func number(_ value: CGFloat) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(Double(value))
    }

    /// Text in one word, as `type` and window titles carry it.
    static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }
}

/// A request to the wrapp's own socket, wrapp.sock, about its info window.
nonisolated public enum WrappRequest: String, Sendable {
    /// `ok open=0|1 warning=0|1`: whether the info window and its save warning show.
    case info
    /// Click I Understand on the save warning: `ok clicked`, or `ok pressed`
    /// when the click didn't take and the wrapp did what the button does.
    case confirm

    public var line: String { rawValue }
}

nonisolated public struct PuppetProtocolError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}
