import Foundation
import Noora
import Subprocess

/// How a step's raw lines become display lines.
enum LineFormat: Sendable {
    /// Shown as they are.
    case plain
    /// Piped through xcbeautify (xcodebuild output).
    case xcbeautify
}

/// Receives one step's output. Every raw line goes to the step's log file
/// whatever the `--logs` mode, so collapsing output never loses anything.
final class LogSink: @unchecked Sendable {
    fileprivate let file: FileHandle?
    fileprivate let raw: @Sendable (String) async -> Void
    private let observers: [@Sendable (String) -> Void]

    init(file: FileHandle?, raw: @escaping @Sendable (String) async -> Void = { _ in }, observers: [@Sendable (String) -> Void] = []) {
        self.file = file
        self.raw = raw
        self.observers = observers
    }

    func line(_ text: String) async {
        try? file?.write(contentsOf: Data((text + "\n").utf8))
        for observe in observers { observe(text) }
        await raw(text)
    }
}

extension UI {
    /// Run a step whose output is a stream of log lines — a build, a test
    /// run, the headless app.
    ///
    /// - collapsed (live): a Noora collapsible step showing the last few
    ///   lines, which collapses to one ✔ line on success. On failure it
    ///   leaves the error lines it saw and the log's path on screen.
    /// - full: every (formatted) line, under a heading.
    /// - raw: every raw line, under a heading.
    ///
    /// `observe` sees every raw line too, for callers that parse the stream
    /// (test progress). xcodebuild steps also get an activity line — what
    /// the build is doing and for how long — live, or as plain lines when a
    /// script phase starts otherwise, since xcbeautify shows neither.
    /// `body` returns the exit status of what it ran; non-zero fails the step.
    @discardableResult
    func logStep(
        _ title: String,
        log name: String,
        formatting: LineFormat = .plain,
        success: String? = nil,
        visibleLines: UInt = 6,
        keepOnSuccess: Bool = true,
        observe: [@Sendable (String) -> Void] = [],
        renderer: RendererHandle? = nil,
        _ body: @escaping (LogSink) async throws -> Int32
    ) async throws -> URL {
        let logURL = try makeLogFile(name)
        let file = try? FileHandle(forWritingTo: logURL)
        defer { try? file?.close() }

        let problems = ProblemCollector()
        let formatWith = (mode == .raw) ? LineFormat.plain : formatting
        let isXcodebuild = formatting == .xcbeautify

        // Live: a spinner line under the step, created after the step's own
        // slot so it draws beneath it.
        let handle = isLive ? (renderer ?? self.renderer()) : nil
        let activity = isLive && isXcodebuild ? ActivityLine(ui: self) : nil
        var observers = observe
        if let activity {
            observers.append { activity.see($0) }
        } else if isXcodebuild, mode == .full {
            // Not live: announce script phases, which can run silently for a long time.
            observers.append { [weak self] raw in
                guard raw.hasPrefix("PhaseScriptExecution"), let text = XcodeActivity.describe(raw) else { return }
                self?.line(self?.format("\(.muted("  ⋯ \(text)"))") ?? text)
            }
        }

        // Lines reach the screen through `show`, which differs per mode.
        let run: (@escaping @Sendable (String) -> Void) async throws -> Int32 = { show in
            try await Self.withFormatter(formatWith, colored: self.environment.isColored) { formatted in
                let sink = LogSink(file: file, raw: { line in
                    if formatWith == .plain {
                        problems.add(line)
                        show(line)
                    } else {
                        await formatted(line)
                    }
                }, observers: observers)
                return try await body(sink)
            } display: { line in
                problems.add(line)
                show(line)
            }
        }

        if let handle {
            var status: Int32 = 0
            activity?.start()
            defer { activity?.stop() }
            do {
                try await noora.collapsibleStep(
                    title: TerminalText(stringLiteral: title),
                    successMessage: success.map { TerminalText(stringLiteral: $0) },
                    errorMessage: TerminalText(stringLiteral: "\(title) failed"),
                    visibleLines: visibleLines,
                    renderer: handle.rendering
                ) { progress in
                    status = try await run { progress(TerminalText(stringLiteral: $0)) }
                    activity?.stop()
                    if status != 0 { throw StepFailed(status: status) }
                }
                // A step inside another (the wrapp build's log tail) can
                // vanish on success: the outer step's ✔ says it all.
                if keepOnSuccess { handle.commit() } else { handle.remove() }
                return logURL
            } catch {
                // Stopped with Ctrl-C: that's not a failure to explain.
                if Task.isCancelled {
                    handle.remove()
                    throw CancellationError()
                }
                handle.commit()
                reportFailure(problems: problems.snapshot(), log: logURL)
                if let failed = error as? StepFailed { throw SCError.reported(exitCode: failed.status) }
                throw error
            }
        }

        line(format("\(.primary("▸ \(title)"))"))
        let status: Int32
        do {
            let indent = mode == .raw ? "" : "  "
            status = try await run { [weak self] in self?.line(indent + $0) }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            line(format("\(.danger("⨯ \(title) failed"))") + "  " + format("\(.muted("log: \(logURL.path)"))"))
            throw error
        }
        if Task.isCancelled { throw CancellationError() }
        if status != 0 {
            line(format("\(.danger("⨯ \(title) failed (exit \(status))"))"))
            line(format("\(.muted("Full log: \(logURL.path)"))"))
            throw SCError.reported(exitCode: status)
        }
        line(format("\(.success("✔︎ \(success ?? title)"))"))
        return logURL
    }

    private func reportFailure(problems: [String], log: URL) {
        if !problems.isEmpty {
            for problem in problems { line("  " + problem) }
        }
        line(format("\(.muted("  Full log: \(log.path)"))"))
    }

    /// A log file for output that is displayed some other way (a live test
    /// region): every line is kept, and `observers` see each one.
    func logOnly(_ name: String, observers: [@Sendable (String) -> Void]) throws -> (sink: LogSink, url: URL) {
        let url = try makeLogFile(name)
        let file = try FileHandle(forWritingTo: url)
        return (LogSink(file: file, observers: observers), url)
    }

    func makeLogFile(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let stamp = Self.timestamp()
        let url = logsDir.appendingPathComponent("\(stamp)-\(name).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Run `body` with a function that formats raw lines. For xcbeautify that
    /// is a long-running xcbeautify process fed through its stdin; its output
    /// arrives at `display`.
    static func withFormatter(
        _ format: LineFormat,
        colored: Bool,
        body: @escaping (@escaping @Sendable (String) async -> Void) async throws -> Int32,
        display: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        guard case .xcbeautify = format, Proc.which("xcbeautify") != nil else {
            return try await body { display($0) }
        }
        var args = ["--renderer", "terminal"]
        if !colored { args.append("--disable-colored-output") }
        let result = try await Subprocess.run(
            .name("xcbeautify"), arguments: Arguments(args),
            platformOptions: Proc.platformOptions,
            input: .inputWriter, output: .sequence, error: .discarded
        ) { execution in
            let writer = execution.standardInputWriter
            // Read xcbeautify's output concurrently with feeding it, or a
            // full pipe would stall both.
            async let reading: Void = {
                for try await line in execution.standardOutput.strings(bufferingPolicy: .unbounded) {
                    display(line)
                }
            }()
            let status: Int32
            do {
                status = try await body { line in
                    _ = try? await writer.write(line + "\n")
                }
            } catch {
                try? await writer.finish()
                try? await reading
                throw error
            }
            try await writer.finish()
            try await reading
            return status
        }
        return result.closureResult
    }
}

struct StepFailed: Error {
    let status: Int32
}

/// Keeps the lines worth showing when a step fails: errors and warnings as
/// xcbeautify marks them (or as compilers print them), else the last lines.
final class ProblemCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var problems: [String] = []
    private var tail: [String] = []
    private let maxProblems = 40
    private let maxTail = 20

    func add(_ line: String) {
        let plain = ANSI.strip(line)
        lock.withLock {
            tail.append(line)
            if tail.count > maxTail { tail.removeFirst() }
            if Self.isProblem(plain), problems.count < maxProblems { problems.append(line) }
        }
    }

    static func isProblem(_ line: String) -> Bool {
        line.contains("❌") || line.contains("✖") || line.contains(" error: ") || line.hasPrefix("error: ")
            || line.contains("** BUILD FAILED **") || line.contains("** TEST BUILD FAILED **")
            || line.contains("** TEST FAILED **") || line.contains("Testing failed:")
            || line.contains("failed with a nonzero exit code") || line.hasPrefix("Failed frontend command")
            || line.contains("fatal error:")
    }

    func snapshot() -> [String] {
        lock.withLock { problems.isEmpty ? tail : problems }
    }
}
