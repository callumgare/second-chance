import Foundation

/// One line of Swift Testing's console output, as xcodebuild prints it.
///
/// Swift Testing starts each line with an SF Symbol (private-use characters
/// like 􀟈 or 􁁛), then e.g. `Test "Display name" started.` or
/// `Suite "Name" passed after 0.1 seconds.` The symbols differ by Xcode
/// version, so lines are recognised by their words, not their symbols.
enum TestEvent: Equatable, Sendable {
    enum Kind: String, Sendable { case test, suite }
    enum Outcome: String, Sendable { case passed, failed, skipped }

    case started(Kind, name: String)
    case finished(Kind, name: String, outcome: Outcome, seconds: Double?)
    /// `Test "x" recorded an issue at File.swift:12:3: Expectation failed: …`
    case issue(name: String, detail: String)
    /// The run's own last line: `Test run with 73 tests in 13 suites passed after 4.9 seconds.`
    case runFinished(passed: Bool)

    static func parse(_ rawLine: String) -> TestEvent? {
        var line = Substring(rawLine)
        // xcodebuild sometimes glues this marker onto the front of a line.
        if line.hasPrefix("XCTestOutputBar") { line = line.dropFirst("XCTestOutputBar".count) }
        // Drop the leading symbol and space.
        guard let first = line.unicodeScalars.first, first.value > 0x7F else { return nil }
        line = line.drop { $0.unicodeScalars.allSatisfy { $0.value > 0x7F } }
        line = line.drop { $0 == " " }

        if line.hasPrefix("Test run ") {
            if line.contains(" passed after ") { return .runFinished(passed: true) }
            if line.contains(" failed after ") { return .runFinished(passed: false) }
            return nil
        }

        let kind: Kind
        if line.hasPrefix("Test ") { kind = .test; line = line.dropFirst(5) }
        else if line.hasPrefix("Suite ") { kind = .suite; line = line.dropFirst(6) }
        else { return nil }

        guard let (name, rest) = splitName(line) else { return nil }
        var tail = rest.drop { $0 == " " }
        // "with 34 test cases passed after …" for parameterised tests.
        if tail.hasPrefix("with "), let range = tail.range(of: " test case") {
            tail = tail[range.upperBound...].drop { $0 != " " }.drop { $0 == " " }
        }

        if tail.hasPrefix("started.") { return .started(kind, name: name) }
        if tail.hasPrefix("passed") { return .finished(kind, name: name, outcome: .passed, seconds: seconds(in: tail)) }
        if tail.hasPrefix("failed") { return .finished(kind, name: name, outcome: .failed, seconds: seconds(in: tail)) }
        if tail.hasPrefix("skipped") { return .finished(kind, name: name, outcome: .skipped, seconds: nil) }
        if tail.hasPrefix("recorded an issue") {
            let detail = tail.dropFirst("recorded an issue".count).drop { $0 == " " || $0 == ":" }
            return .issue(name: name, detail: String(detail))
        }
        return nil
    }

    /// The name is either quoted (`"Display name"`, which may itself contain
    /// quotes) or a bare function name (`foo()`).
    private static func splitName(_ text: Substring) -> (String, Substring)? {
        if text.hasPrefix("\"") {
            let verbs = ["\" started.", "\" passed", "\" failed", "\" skipped", "\" recorded", "\" with "]
            var best: Range<Substring.Index>?
            for verb in verbs {
                if let range = text.range(of: verb), range.lowerBound > text.startIndex {
                    if best == nil || range.lowerBound < (best?.lowerBound ?? text.endIndex) { best = range }
                }
            }
            guard let end = best?.lowerBound else { return nil }
            let name = text[text.index(after: text.startIndex)..<end]
            return (String(name), text[text.index(after: end)...])
        }
        guard let space = text.firstIndex(of: " ") else { return nil }
        return (String(text[..<space]), text[space...])
    }

    private static func seconds(in text: Substring) -> Double? {
        guard let range = text.range(of: "after ") else { return nil }
        let number = text[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(number)
    }
}

/// Counting tests from `xcodebuild -enumerate-tests -test-enumeration-format json`.
enum TestEnumeration {
    static func countEnabledTests(json data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["values"] as? [[String: Any]] else { return nil }
        func count(_ node: [String: Any]) -> Int {
            if node["disabled"] as? Bool == true { return 0 }
            if node["kind"] as? String == "test" { return 1 }
            return (node["children"] as? [[String: Any]] ?? []).reduce(0) { $0 + count($1) }
        }
        return values.reduce(0) { $0 + count($1) }
    }
}

/// The state of a test run, built from `TestEvent`s, that the live display
/// and the final tables read.
final class TestBoard: @unchecked Sendable {
    enum Status: String, Sendable { case running, passed, failed, skipped }

    struct Suite: Sendable {
        let name: String
        var status: Status
        var seconds: Double?
        let order: Int
    }

    struct Failure: Sendable {
        let test: String
        var details: [String]
    }

    private let lock = NSLock()
    private(set) var suites: [String: Suite] = [:]
    private var running: [String] = []
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var skipped = 0
    private(set) var failures: [Failure] = []
    let total: Int?
    private var onChange: [@Sendable () -> Void] = []

    init(total: Int?) { self.total = total }

    func observe(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { onChange.append(handler) }
    }

    /// Returns a line worth keeping on screen for this event (a failure), if any.
    @discardableResult
    func apply(_ event: TestEvent) -> String? {
        var keep: String?
        lock.withLock {
            switch event {
            case .started(.suite, let name):
                suites[name] = Suite(name: name, status: .running, seconds: nil, order: suites.count)
            case .finished(.suite, let name, let outcome, let seconds):
                let order = suites[name]?.order ?? suites.count
                suites[name] = Suite(name: name, status: Status(outcome), seconds: seconds, order: order)
            case .started(.test, let name):
                running.append(name)
            case .finished(.test, let name, let outcome, _):
                running.removeAll { $0 == name }
                switch outcome {
                case .passed: passed += 1
                case .failed:
                    failed += 1
                    if !failures.contains(where: { $0.test == name }) { failures.append(Failure(test: name, details: [])) }
                    keep = "✘ \(name) failed"
                case .skipped: skipped += 1
                }
            case .issue(let name, let detail):
                if let index = failures.firstIndex(where: { $0.test == name }) {
                    failures[index].details.append(detail)
                } else {
                    failures.append(Failure(test: name, details: [detail]))
                }
                keep = "  ✘ \(name): \(detail)"
            case .runFinished:
                running.removeAll()
            }
        }
        for handler in lock.withLock({ onChange }) { handler() }
        return keep
    }

    var finishedCount: Int { lock.withLock { passed + failed + skipped } }

    var fraction: Double {
        lock.withLock {
            guard let total, total > 0 else { return 0 }
            return min(Double(passed + failed + skipped) / Double(total), 1)
        }
    }

    /// One line: counts, then what's running now.
    var statusLine: String {
        lock.withLock {
            var parts = ["\(passed + failed + skipped)\(total.map { "/\($0)" } ?? "") tests"]
            if failed > 0 { parts.append("\(failed) failed") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            if let current = running.last { parts.append(current) }
            return parts.joined(separator: " · ")
        }
    }

    /// In the order the suites started, so rows don't move as they finish.
    var suiteRows: [Suite] {
        lock.withLock { suites.values.sorted { $0.order < $1.order } }
    }

    var snapshotFailures: [Failure] { lock.withLock { failures } }
}

extension TestBoard.Status {
    init(_ outcome: TestEvent.Outcome) {
        switch outcome {
        case .passed: self = .passed
        case .failed: self = .failed
        case .skipped: self = .skipped
        }
    }
}
