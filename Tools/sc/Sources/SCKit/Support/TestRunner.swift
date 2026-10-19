import Foundation
import GameCatalog
import Noora

/// One finished xcodebuild test run.
struct TestRun: Sendable {
    let name: String
    let status: Int32
    let bundle: URL
    let summary: TestReports.Summary?
}

/// Runs the unit and integration suites and shows them live: a progress bar,
/// a line saying what's running now, and a table that fills in as suites or
/// games finish. Without a live terminal the same runs print plain lines and
/// a table at the end.
struct TestRunner {
    let session: Session
    var repo: Repo { session.repo }
    var ui: UI { session.ui }
    var xcode: Xcode { Xcode(session: session) }

    /// Suites that are not part of the unit run. Everything else is, so a new
    /// suite runs by default instead of silently never running.
    static let unitExclusions = [
        // Real installs, hours for all games: `sc test integration`.
        "DiskInstallIntegrationTests",
        // Shell out to the bundled exiftool.
        "ExiftoolServiceTests",
        "ExiftoolServiceIntegrationTests",
    ]

    static var unitSelection: [String] {
        unitExclusions.map { "-skip-testing:SecondChanceTests/\($0)" }
    }

    static let integrationSelection = [
        "-parallel-testing-worker-count", "1",
        "-only-testing:SecondChanceTests/DiskInstallIntegrationTests",
    ]

    // MARK: - Unit

    func unit(stamp: String) async throws -> TestRun {
        let bundle = repo.testResults.appendingPathComponent("\(stamp)-unit.xcresult")
        let total = try? await ui.progressStep("Counting unit tests", success: "Counted unit tests") { _ in
            try await xcode.countTests(selection: Self.unitSelection)
        }
        let board = TestBoard(total: total ?? nil)
        let live = ui.isLive
        let observer: @Sendable (String) -> Void = { [ui] line in
            guard let event = TestEvent.parse(line) else { return }
            if let keep = board.apply(event), live { ui.line(ui.format("\(.danger(keep))")) }
        }
        let env = ["TEST_RUNNER_REPO_ROOT": repo.root.path]

        let status = try await runSuite(
            title: "Unit tests", log: "test-unit", observer: observer,
            fraction: { board.fraction },
            statusLine: { board.statusLine },
            table: { suiteTable(board) }
        ) { sink in
            try await xcode.runTests(selection: Self.unitSelection, environment: env, resultBundle: bundle, sink: sink)
        }
        await ui.table(headers: suiteTable(board).headers, rows: suiteTable(board).rows)
        return TestRun(name: "Unit", status: status, bundle: bundle, summary: await TestReports.summary(of: bundle))
    }

    private func suiteTable(_ board: TestBoard) -> (headers: [String], rows: [StyledTableRow]) {
        let rows: [StyledTableRow] = board.suiteRows.map { suite in
            [.plain(suite.name), statusCell(suite.status.rawValue), .muted(suite.seconds.map { String(format: "%.1fs", $0) } ?? "")]
        }
        return (["Suite", "Result", "Time"], rows)
    }

    // MARK: - Integration

    func integration(games requested: [CatalogGame], refresh: WrappRefresh, wrappsDir: URL, ignoreLoad: Bool = false, stamp: String) async throws -> TestRun {
        let games = requested.isEmpty ? Catalog.games : requested
        if refresh != .full {
            let builder = WrappBuilder(session: session)
            let wrapps = try games.map { try builder.existingWrapp($0, in: wrappsDir) }
            if refresh == .template {
                for wrapp in wrapps { try await builder.updateTemplate(of: wrapp) }
            }
        }

        let bundle = repo.testResults.appendingPathComponent("\(stamp)-integration.xcresult")
        let progressFile = FileManager.default.temporaryDirectory.appendingPathComponent("sc-test-progress-\(UUID().uuidString).jsonl")
        let follower = ProgressFollower(url: progressFile)
        defer { follower.remove() }

        var env = [
            "TEST_RUNNER_REPO_ROOT": repo.root.path,
            // Asked for by name, so missing ISOs are a failure, not a skip
            // that would report a pass having tested nothing.
            "TEST_RUNNER_REQUIRE_INSTALLERS": "1",
            "TEST_RUNNER_PROGRESS_PATH": progressFile.path,
            "TEST_RUNNER_WRAPPS_DIR": wrappsDir.path,
        ]
        if !requested.isEmpty { env["TEST_RUNNER_TEST_GAMES"] = requested.map(\.slug).joined(separator: ",") }
        if refresh != .full { env["TEST_RUNNER_SKIP_BUILD"] = "1" }
        if ignoreLoad { env["TEST_RUNNER_IGNORE_LOAD"] = "1" }
        let environment = env

        let board = GameBoard(games: games)
        let live = ui.isLive
        let following = follower.follow { record in
            if record.event == "load", let message = record.message {
                ui.warning("\(message)")
                return
            }
            if let line = board.apply(record), !live { ui.line(line) }
        }
        defer { following.cancel() }
        let observer: @Sendable (String) -> Void = { [ui] line in
            guard live, let event = TestEvent.parse(line), case .issue(_, let detail) = event else { return }
            ui.line(ui.format("\(.danger("  ✘ \(detail)"))"))
        }

        let status = try await runSuite(
            title: "Integration tests", log: "test-integration", observer: observer,
            fraction: { board.fraction },
            statusLine: { board.statusLine },
            table: { gameTable(board) }
        ) { sink in
            try await xcode.runTests(selection: Self.integrationSelection, environment: environment, resultBundle: bundle, sink: sink)
        }
        for record in follower.poll() { board.apply(record) }
        await ui.table(headers: gameTable(board).headers, rows: gameTable(board).rows)
        if board.hasOverloadedGames {
            ui.warning("Some games weren't tested: the Mac was heavily loaded, so Wine would have taken minutes to start, or never started.",
                       next: "Quit the busy programs and run those games again, or pass --ignore-load to test them anyway.")
        }
        if board.hasPermissionProblems {
            ui.warning("WrappPuppeteer was missing a permission (exit 3–5) — that's a TCC grant, not a regression.",
                       next: "See the WrappPuppeteer section of docs/testing.md.")
        }
        return TestRun(name: "Integration", status: status, bundle: bundle, summary: await TestReports.summary(of: bundle))
    }

    private func gameTable(_ board: GameBoard) -> (headers: [String], rows: [StyledTableRow]) {
        let rows: [StyledTableRow] = board.rows.map { game in
            [.plain(game.slug), .muted(game.engine), statusCell(game.status), .muted(game.seconds.map { String(format: "%.0fs", $0) } ?? "")]
        }
        return (["Game", "Engine", "Result", "Time"], rows)
    }

    private func statusCell(_ status: String) -> TableCellStyle {
        switch status {
        case "passed": .success(status)
        case "failed": .danger(status)
        case "permission": .warning(status)
        case "overloaded": .warning(status)
        case "running": .accent(status)
        default: .muted(status)
        }
    }

    // MARK: - Running and showing a suite

    /// Run one xcodebuild test run. Live: a progress bar, a status line and
    /// a table, redrawn as the run goes. Otherwise: the run's output as a
    /// log step (formatted, or raw). Returns xcodebuild's exit status rather
    /// than throwing on test failures, so the caller can still report.
    private func runSuite(
        title: String,
        log: String,
        observer: @escaping @Sendable (String) -> Void,
        fraction: @escaping @Sendable () -> Double,
        statusLine: @escaping @Sendable () -> String,
        table: @escaping @Sendable () -> (headers: [String], rows: [StyledTableRow]),
        run: @escaping @Sendable (LogSink) async throws -> Int32
    ) async throws -> Int32 {
        guard ui.isLive else {
            do {
                var status: Int32 = 0
                try await ui.logStep(title, log: log, formatting: .xcbeautify, observe: [observer]) { sink in
                    status = try await run(sink)
                    return status
                }
                return status
            } catch let error as SCError where error.alreadyReported {
                return error.exitCode
            }
        }

        let (sink, logURL) = try ui.logOnly(log, observers: [observer])
        let bar = ui.renderer()
        let statusSlot = ui.renderer()
        let liveTable = ui.liveTable(headers: table().headers)
        let noora = ui.noora
        let ui = self.ui
        let finished = DoneFlag()
        let running = Task {
            defer { finished.set() }
            return try await run(sink)
        }

        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try await noora.progressBarStep(
                    message: title, successMessage: "\(title) passed", errorMessage: "\(title) failed",
                    renderer: bar.rendering
                ) { progress in
                    let pipeline = RegionAwarePipeline(region: ui.region)
                    while true {
                        progress(fraction())
                        statusSlot.rendering.render(ui.format("\(.muted("  \(statusLine())"))"), standardPipeline: pipeline)
                        liveTable.update(table().rows)
                        if finished.isSet { break }
                        try await Task.sleep(for: .milliseconds(150))
                    }
                    let status = try await running.value
                    if status != 0 { throw StepFailed(status: status) }
                    return status
                }
            } onCancel: {
                running.cancel()
            }
        } catch let failed as StepFailed {
            status = failed.status
        }
        statusSlot.remove()
        // The final table is printed by the caller, below the bar's ✔ line.
        await liveTable.finish(keep: false)
        bar.commit()
        if status != 0 { ui.detail("  Full log: \(logURL.path)") }
        return status
    }
}

/// Set once, read from a polling loop.
final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() { lock.withLock { done = true } }
    var isSet: Bool { lock.withLock { done } }
}

/// The state of an integration run, game by game, from the progress stream.
final class GameBoard: @unchecked Sendable {
    struct Row: Sendable {
        let slug: String
        let engine: String
        var status: String
        var stage: String?
        var seconds: Double?
    }

    private let lock = NSLock()
    private var rowsBySlug: [String: Row]
    private let order: [String]
    private var current: String?

    init(games: [CatalogGame]) {
        order = games.map(\.slug)
        rowsBySlug = Dictionary(uniqueKeysWithValues: games.map { ($0.slug, Row(slug: $0.slug, engine: $0.engine, status: "pending")) })
    }

    /// Apply a record; returns a plain line describing it, for non-live output.
    @discardableResult
    func apply(_ record: ProgressRecord) -> String? {
        lock.withLock {
            switch record.event {
            case "game":
                guard let slug = record.slug else { return nil }
                var row = rowsBySlug[slug] ?? Row(slug: slug, engine: "", status: "pending")
                switch record.phase {
                case "started":
                    row.status = "running"
                    row.stage = "starting"
                    current = slug
                case "finished":
                    row.status = record.result ?? "failed"
                    row.seconds = record.seconds
                    row.stage = nil
                    if current == slug { current = nil }
                default:
                    row.stage = record.phase
                }
                rowsBySlug[slug] = row
                return "▸ \(slug): \(record.phase ?? "")\(record.result.map { " (\($0))" } ?? "")"
            case "stage":
                guard let slug = current, let text = record.text else { return nil }
                rowsBySlug[slug]?.stage = text
                return nil
            default:
                return nil
            }
        }
    }

    /// In the catalogue's order, which never changes: rows don't jump
    /// around as games finish. The status line names the running game even
    /// when a short window trims the table.
    var rows: [Row] {
        lock.withLock { order.compactMap { rowsBySlug[$0] } }
    }

    var fraction: Double {
        lock.withLock {
            guard !order.isEmpty else { return 0 }
            let done = rowsBySlug.values.filter { !["pending", "running"].contains($0.status) }.count
            return Double(done) / Double(order.count)
        }
    }

    var statusLine: String {
        lock.withLock {
            let done = rowsBySlug.values.filter { !["pending", "running"].contains($0.status) }.count
            var line = "\(done)/\(order.count) games"
            if let current, let row = rowsBySlug[current] {
                line += " · \(current): \(row.stage ?? "running")"
            }
            return line
        }
    }

    var hasOverloadedGames: Bool {
        lock.withLock { rowsBySlug.values.contains { $0.status == "overloaded" } }
    }

    var hasPermissionProblems: Bool {
        lock.withLock { rowsBySlug.values.contains { $0.status == "permission" } }
    }
}
