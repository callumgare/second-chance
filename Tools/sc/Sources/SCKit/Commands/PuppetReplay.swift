import ArgumentParser
import Foundation
import PuppetProtocol

/// What the input recorder wrote: the clicks and keys a person gave a game,
/// which `sc puppet replay` gives it again
/// (`Packages/Modules/wine/InProcessHelpers/input_recorder.m`,
/// docs/dev-cli.md#replaying-a-recording).
struct InputRecording: Equatable {
    /// One line of the file after its first.
    struct Event: Decodable, Equatable {
        var t: Double
        var event: String
        var button: String?
        var x: Double?
        var y: Double?
        var key: String?
        var mods: String?
    }

    /// One thing to do: a press and its release close together are a click.
    struct Step: Equatable {
        enum Action: Equatable {
            /// A share of the picture across and down, and how long it was held.
            case click(x: Double, y: Double, button: MouseButton, holdMilliseconds: Int)
            case down(x: Double, y: Double, button: MouseButton)
            case up(x: Double, y: Double, button: MouseButton)
            /// In the key notation (`escape`, `cmd+s`).
            case key(String)
        }

        /// Seconds since the recorder armed.
        var time: Double
        var action: Action

        var description: String {
            switch action {
            case let .click(x, y, button, _): return "\(button == .right ? "right-click" : "click") \(Self.share(x)),\(Self.share(y))"
            case let .down(x, y, button): return "\(button.rawValue) down \(Self.share(x)),\(Self.share(y))"
            case let .up(x, y, button): return "\(button.rawValue) up \(Self.share(x)),\(Self.share(y))"
            case let .key(keys): return "key \(keys)"
            }
        }

        static func share(_ value: Double) -> String { String(format: "%.3f", value) }
    }

    /// A press held longer than this, or released this far from where it
    /// went down, is replayed as a press and a release, not a click.
    static let longestClick = 1.0
    static let furthestClick = 0.01

    var exe: String?
    var started: String?
    var steps: [Step]

    /// Where `sc wrapp run --debug record-input` records.
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SecondChance/recordings")
    }

    /// A new file to record into, its folder made.
    static func newFile(now: Date = Date()) -> URL {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            // The helper says it couldn't open the file, in the wrapp's log.
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return folder.appendingPathComponent("input-\(formatter.string(from: now)).jsonl")
    }

    static func read(_ url: URL) throws -> InputRecording {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    static func parse(_ text: String) throws -> InputRecording {
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first, let header = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
              header["format"] as? Int == 1 else {
            throw SCError("That isn't a recording of clicks and keys (its first line should say \"format\":1).")
        }
        let decoder = JSONDecoder()
        var events: [Event] = []
        for (index, line) in lines.dropFirst().enumerated() {
            do {
                events.append(try decoder.decode(Event.self, from: Data(line.utf8)))
            } catch {
                // A recording cut off mid-line by the game ending: the rest stands.
                if index == lines.count - 2 { break }
                throw SCError("Line \(index + 2) of the recording can't be read: \(error)")
            }
        }
        return InputRecording(exe: header["exe"] as? String, started: header["started"] as? String, steps: steps(from: events))
    }

    /// The events as steps: each press followed by its release, soon and
    /// near, is one click.
    static func steps(from events: [Event]) -> [Step] {
        var steps: [Step] = []
        var index = 0
        while index < events.count {
            let event = events[index]
            index += 1
            if event.event == "key", let key = event.key {
                let mods = event.mods.map { $0.isEmpty ? "" : $0 + "+" } ?? ""
                steps.append(Step(time: event.t, action: .key(mods + key)))
                continue
            }
            guard let x = event.x, let y = event.y, let button = MouseButton(rawValue: event.button ?? "left") else { continue }
            if event.event == "down" {
                if index < events.count, case let next = events[index], next.event == "up", next.button == event.button,
                   let x2 = next.x, let y2 = next.y, next.t - event.t <= longestClick,
                   abs(x2 - x) <= furthestClick, abs(y2 - y) <= furthestClick {
                    index += 1
                    let hold = max(60, Int(((next.t - event.t) * 1000).rounded()))
                    steps.append(Step(time: event.t, action: .click(x: x, y: y, button: button, holdMilliseconds: hold)))
                } else {
                    steps.append(Step(time: event.t, action: .down(x: x, y: y, button: button)))
                }
            } else if event.event == "up" {
                steps.append(Step(time: event.t, action: .up(x: x, y: y, button: button)))
            }
        }
        return steps
    }

    /// A share of the picture as a point in the window.
    static func point(x: Double, y: Double, picture: CGRect) -> CGPoint {
        CGPoint(x: (picture.minX + x * picture.width).rounded(), y: (picture.minY + y * picture.height).rounded())
    }

    /// The request that does `action` where the picture is now.
    static func request(_ action: Step.Action, picture: CGRect) throws -> PuppetRequest {
        switch action {
        case let .click(x, y, button, hold):
            return .click(point(x: x, y: y, picture: picture), button: button, hold: hold)
        case let .down(x, y, button):
            return .down(point(x: x, y: y, picture: picture), button: button)
        case let .up(x, y, button):
            return .up(point(x: x, y: y, picture: picture), button: button)
        case let .key(keys):
            do {
                return try PuppetRequest.keys(keys, hold: nil)
            } catch let error as PuppetProtocolError {
                throw SCError("The recording's key \(keys) can't be pressed: \(error.description)")
            }
        }
    }

    /// The frame rates Wine's `fps` channel logged in `text`
    /// (`trace:fps:… @ approx 55.90fps`).
    static func frameRates(in text: String) -> [Double] {
        text.matches(of: /approx (\d+(?:\.\d+)?)\s*fps/).compactMap { Double($0.output.1) }
    }
}

struct PuppetReplayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "replay",
        abstract: "Give the game a recording's clicks and keys again (sc wrapp run --debug record-input), saying how long each took to settle.",
        discussion: """
        Each step waits for the picture to go still after the step before \
        (--settle seconds, up to --timeout) and at least the recording's own \
        gap, up to --max-gap, so a slow scene is waited for rather than \
        clicked through. Clicks are placed by their share of the game's \
        picture, so they land where the person clicked on a screen of any \
        shape. Started with --debug wine=+fps, each step also says the frame \
        rates Wine logged until the next. See docs/dev-cli.md#replaying-a-recording.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument var name: String
    @Argument(help: "The recording: a .jsonl file the input recorder wrote.") var recording: String

    @Option(help: "The first step to do (from 1).") var from: Int = 1
    @Option(help: "The last step to do.") var to: Int?
    @Option(help: "Seconds the picture must be still for before the next step.") var settle: Double = 1.0
    @Option(help: "Seconds to wait for it to go still before going on anyway.") var timeout: Double = 30
    @Option(help: "Most of the recording's own gap between two steps to wait, in seconds.") var maxGap: Double = 2
    @Option(help: "How much of the picture may change, in %, and still count as still (snow, flicker).") var stillThreshold: Int = 2

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        guard puppet.isRunning else { throw SCError("\(name) has stopped: \(puppet.stopReason ?? "?").", exitCode: 4) }
        let file = URL(fileURLWithPath: (recording as NSString).expandingTildeInPath)
        let recorded = try InputRecording.read(file)
        let last = min(to ?? recorded.steps.count, recorded.steps.count)
        guard from >= 1, from <= last else { throw ValidationError("The recording has \(recorded.steps.count) steps: --from and --to are within them.") }
        session.ui.line("\(file.lastPathComponent): \(recorded.steps.count) steps from \(recorded.exe ?? "?"), recorded \(recorded.started ?? "?")")

        // The game's opening (its logos, a video) plays out before the first
        // step: until the game has run as long as it had when the person
        // first acted (the recorder starts with the game), then until the
        // picture is still. A held logo is still too, so stillness alone
        // started a new game from the logo's menu.
        if from == 1, let first = recorded.steps.first {
            let pid = (try? puppet.ask(.hello, timeout: 10))?.fields["pid"].flatMap { Int32($0) }
            if let started = pid.flatMap(ProcessFacts.startTime(of:)) {
                let wait = first.time - (Date().timeIntervalSince1970 - started)
                if wait > 0 {
                    session.ui.line(String(format: "waiting %.0f s for the game to be as far in as when the person first acted", wait))
                    try await Task.sleep(for: .seconds(wait))
                }
            }
        }
        if let settled = try await waitUntilStill(puppet, sent: Date()) {
            session.ui.line(String(format: "the picture went still after %.1f s: starting", settled))
        } else {
            session.ui.line(String(format: "the picture wasn't still after %.0f s: starting anyway", timeout))
        }
        // Wine's lines, its fps channel's among them, go to the wrapp's own
        // log, which wrapp.log names as the wrapp starts.
        let log = Self.wrappLogFile(named: Self.text(of: puppet.wrappLog, from: 0)) ?? puppet.wrappLog

        var results: [(index: Int, step: InputRecording.Step, settled: Double?, rates: [Double])] = []
        var previousTime = from > 1 ? recorded.steps[from - 2].time : 0
        for index in (from - 1)..<last {
            puppet.touch()
            let step = recorded.steps[index]
            // At least the person's own gap (they waited for something), but
            // not their idle minutes.
            let gap = min(max(0, step.time - previousTime), maxGap)
            previousTime = step.time
            if gap > 0 { try await Task.sleep(for: .seconds(gap)) }
            guard puppet.wrappPID.map({ kill($0, 0) == 0 }) ?? false else {
                session.ui.line("the program ended before step \(index + 1)")
                throw ExitCode(4)
            }
            let window = (try? puppet.ask(.state, timeout: 10)).flatMap(PuppetWindowState.init)
            guard let window else { throw SCError("\(name)'s game didn't say where its window is before step \(index + 1).") }
            let picture = window.picture ?? CGRect(origin: .zero, size: window.size)
            let request = try InputRecording.request(step.action, picture: picture)
            let logStart = Self.size(of: log)
            let before = Probe.thumbnail(puppet)
            let sent = Date()
            puppet.noteAction("replay \(index + 1): \(step.description)")
            _ = try puppet.ask(request, timeout: request.timeout)
            let settled = try await waitUntilStill(puppet, sent: sent)
            let after = Probe.thumbnail(puppet)
            let rates = InputRecording.frameRates(in: Self.text(of: log, from: logStart))
            results.append((index + 1, step, settled, rates))
            var line = String(format: "%4d/%d  t=%6.1f  %@", index + 1, recorded.steps.count, step.time, step.description)
            if let a = before, let b = after { line += " → changed \(Frames.changed(a, b))%" }
            line += settled.map { String(format: " · still after %.1f s", $0) } ?? String(format: " · not still after %.0f s", timeout)
            if let summary = Self.rateSummary(rates) { line += " · \(summary)" }
            session.ui.line(line)
        }

        let slowest = results.sorted { ($0.settled ?? .infinity) > ($1.settled ?? .infinity) }.prefix(5)
        session.ui.line("slowest to settle: " + slowest.map { result in
            "\(result.index) (\(result.settled.map { String(format: "%.1f s", $0) } ?? "never"))"
        }.joined(separator: ", "))
        let all = results.flatMap(\.rates)
        if let summary = Self.rateSummary(all) {
            let lowest = results.filter { !$0.rates.isEmpty }.sorted { ($0.rates.min() ?? 0) < ($1.rates.min() ?? 0) }.prefix(5)
            session.ui.line("frame rates over the replay: \(summary); lowest at steps "
                            + lowest.map { "\($0.index) (\(String(format: "%.1f", $0.rates.min() ?? 0)))" }.joined(separator: ", "))
        }
    }

    /// Seconds from `sent` until the picture has been still for `settle`
    /// seconds, not counting that stillness; nil if it never was.
    private func waitUntilStill(_ puppet: PuppetSession, sent: Date) async throws -> Double? {
        var last = Probe.thumbnail(puppet)
        var stillSince = Date()
        while Date().timeIntervalSince(sent) < timeout {
            try await Task.sleep(for: .seconds(0.25))
            let now = Probe.thumbnail(puppet)
            if let a = last, let b = now, Frames.changed(a, b) > stillThreshold { stillSince = Date() }
            if last == nil || now == nil { stillSince = Date() }
            last = now
            if Date().timeIntervalSince(stillSince) >= settle { return max(0, stillSince.timeIntervalSince(sent)) }
            guard puppet.wrappPID.map({ kill($0, 0) == 0 }) ?? false else { return nil }
        }
        return nil
    }

    /// The wrapp's own log, from the `log: <path>` line it starts with.
    static func wrappLogFile(named output: String) -> URL? {
        guard let match = output.firstMatch(of: /(?m)^\s*log: (\/.+\.log)\s*$/) else { return nil }
        return URL(fileURLWithPath: String(match.output.1))
    }

    static func rateSummary(_ rates: [Double]) -> String? {
        guard !rates.isEmpty else { return nil }
        let sorted = rates.sorted()
        return String(format: "fps median %.1f, min %.1f", sorted[sorted.count / 2], sorted[0])
    }

    static func size(of file: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// What `file` gained after `offset`.
    static func text(of file: URL, from offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        } catch {
            return ""
        }
    }
}
