import Foundation
import Noora
import WrappBuilder

/// One finished xcodebuild test run.
struct TestRun: Sendable {
    let name: String
    let status: Int32
    let bundle: URL
    let summary: TestReports.Summary?
    /// An integration run's games, as its table shows them.
    var games: [GameBoard.Row] = []
}

/// What `sc test integration --source` picks: a build source's suite. Big
/// Fish has two, the full games the test account owns and every game's free
/// trial, which `wrapp build` tells apart with `--big-fish-trial` instead.
enum IntegrationSource: String, CaseIterable, Sendable {
    case disk
    case steam
    case herDownload = "her-download"
    case bigFish = "big-fish"
    case bigFishTrial = "big-fish-trial"
    case download

    /// Whether the source's suite tests `game`, given the games sold on
    /// disc, those with Her downloads in the installers store and those with a
    /// download edition.
    func tests(_ game: CatalogGame, discs: Set<String>, herDownloads: Set<String>, downloads: Set<String>) -> Bool {
        switch self {
        case .disk: discs.contains(game.slug)
        case .steam: game.isOnSteam
        case .herDownload: herDownloads.contains(game.slug)
        case .bigFish, .bigFishTrial: game.isOnBigFish
        case .download: downloads.contains(game.slug)
        }
    }
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
        // Real Steam downloads: `sc test integration --source steam`.
        "SteamInstallIntegrationTests",
        // Real installs from Her downloads: `sc test integration --source her-download`.
        "HerDownloadInstallIntegrationTests",
        // Real Big Fish downloads: `sc test integration --source big-fish` and `big-fish-trial`.
        "BigFishOwnedInstallIntegrationTests",
        "BigFishTrialInstallIntegrationTests",
        // Real downloads of free games: `sc test integration --source download`.
        "DownloadInstallIntegrationTests",
    ]

    static var unitSelection: [String] {
        unitExclusions.map { "-skip-testing:SecondChanceTests/\($0)" }
    }

    /// The suite that tests each source's builds.
    static func integrationSuite(_ source: IntegrationSource) -> String {
        switch source {
        case .disk: "DiskInstallIntegrationTests"
        case .steam: "SteamInstallIntegrationTests"
        case .herDownload: "HerDownloadInstallIntegrationTests"
        case .bigFish: "BigFishOwnedInstallIntegrationTests"
        case .bigFishTrial: "BigFishTrialInstallIntegrationTests"
        case .download: "DownloadInstallIntegrationTests"
        }
    }

    static func integrationSelection(_ sources: [IntegrationSource]) -> [String] {
        ["-parallel-testing-worker-count", "1"] + sources.map { "-only-testing:SecondChanceTests/\(integrationSuite($0))" }
    }

    /// The `.env` setting that has the test host keep its windows out of the
    /// way (`TestHost.hidesUI`): set on a Mac someone is using while tests
    /// run, left out on a test Mac, where seeing them helps with a failure.
    static let hideUISetting = "SECOND_CHANCE_HIDE_TEST_UI"

    /// What the test host gets from `.env`, as xcodebuild's `TEST_RUNNER_`
    /// variables (passed on to it without the prefix).
    static func hostEnvironment(dotEnv: [String: String]) -> [String: String] {
        guard let value = dotEnv[hideUISetting], !value.isEmpty else { return [:] }
        return ["TEST_RUNNER_\(hideUISetting)": value]
    }

    /// `--keep-recordings`: every launch's screen recording kept, and given
    /// longer to run (docs/testing.md#wrapppuppeteer).
    static func recordingEnvironment(keepRecordings: Bool) -> [String: String] {
        guard keepRecordings else { return [:] }
        return ["TEST_RUNNER_KEEP_RECORDINGS": "1", "TEST_RUNNER_RECORDING_LIMIT": "\(IntegrationOptions.keptRecordingLimit)"]
    }

    /// The Big Fish test account from `.env`, for the owned Big Fish suite
    /// only: the test host signs in with it (`BIG_FISH_EMAIL`,
    /// `BIG_FISH_PASSWORD`). Nothing when the suite isn't run or the account
    /// isn't there, in which case the suite skips itself.
    static func bigFishEnvironment(dotEnv: [String: String], sources: [IntegrationSource]) -> [String: String] {
        guard sources.contains(.bigFish), let account = BigFishSourceOptions.testAccount(dotEnv: dotEnv) else { return [:] }
        return Dictionary(uniqueKeysWithValues: account.map { ("TEST_RUNNER_\($0.key)", $0.value) })
    }

    // MARK: - Unit

    /// The app's unit suites: every one but the integration suites, or only
    /// `only` (each `Suite` or `Suite/test()`).
    func unit(stamp: String, only: [String]? = nil) async throws -> TestRun {
        let bundle = repo.testResults.appendingPathComponent("\(stamp)-unit.xcresult")
        let selection = only.map { $0.map { "-only-testing:SecondChanceTests/\($0)" } } ?? Self.unitSelection
        let total = try? await ui.progressStep("Counting unit tests", success: "Counted unit tests") { _ in
            try await xcode.countTests(selection: selection)
        }
        let board = TestBoard(total: total ?? nil)
        let live = ui.isLive
        let observer: @Sendable (String) -> Void = { [ui] line in
            guard let event = TestEvent.parse(line) else { return }
            if let keep = board.apply(event), live { ui.line(ui.format("\(.danger(keep))")) }
        }
        // The detection suite reads every disc image and Her download in the store.
        let env = ["TEST_RUNNER_REPO_ROOT": repo.root.path, "TEST_RUNNER_\(InstallersStore.environmentVariable)": repo.installers.root.path]
            .merging(Self.hostEnvironment(dotEnv: DotEnv.load(repo))) { _, new in new }

        let status = try await runSuite(
            title: "Unit tests", log: "test-unit", observer: observer,
            fraction: { board.fraction },
            statusLine: { board.statusLine },
            table: { suiteTable(board) },
            run: { sink in
                try await xcode.runTests(selection: selection, environment: env, resultBundle: bundle, sink: sink)
            }
        )
        await ui.table(headers: suiteTable(board).headers, rows: suiteTable(board).rows)
        return TestRun(name: "Unit", status: status, bundle: bundle, summary: await TestReports.summary(of: bundle))
    }

    private func suiteTable(_ board: TestBoard) -> (headers: [String], rows: [StyledTableRow]) {
        let rows: [StyledTableRow] = board.suiteRows.map { suite in
            [.plain(suite.name), Self.statusCell(suite.status.rawValue), .muted(suite.seconds.map { String(format: "%.1fs", $0) } ?? "")]
        }
        return (["Suite", "Result", "Time"], rows)
    }

    // MARK: - Integration

    func integration(
        games requested: [CatalogGame], sources: [IntegrationSource] = [.disk], refresh: WrappRefresh, wrappsDir: URL,
        ignoreLoad: Bool = false, keepFailedBuilds: Bool = false, buildConcurrency: Int = 1, diskMargin: Double = 10,
        keepRecordings: Bool = false, vm: TestVM.Prepared? = nil, stamp: String
    ) async throws -> TestRun {
        let games = requested.isEmpty ? Catalog.games : requested
        // Each source tests the games it can build: the Steam suite, those on
        // Steam; the Her suite, those with a Her download in the installers store; the
        // Big Fish suites, those Big Fish sells; the download suite, those
        // with a download edition.
        let soldOnDisc = Set(Catalog.games.filter { $0.hasEdition(source: "disc", repo: repo) }.map(\.slug))
        let withHerDownloads = Set(Games.withHerDownloads(repo: repo).map(\.slug))
        let toDownload = Set(DownloadSourceOptions().availableGames(repo: repo).map(\.slug))
        let entries = sources.flatMap { source in
            games.filter { source.tests($0, discs: soldOnDisc, herDownloads: withHerDownloads, downloads: toDownload) }
                .map { (source: source.rawValue, game: $0) }
        }
        if entries.isEmpty {
            throw SCError("None of those games can be built from \(sources.map(\.rawValue).joined(separator: " or ")).",
                          hints: ["Games on Steam: \(Catalog.games.filter(\.isOnSteam).map(\.slug).joined(separator: ", "))",
                                  "Games with Her downloads: \(withHerDownloads.sorted().joined(separator: ", "))",
                                  "Games on Big Fish: \(Catalog.games.filter(\.isOnBigFish).map(\.slug).joined(separator: ", "))"])
        }
        await LeakedHelpers.clear(ui: ui)
        let helpersBefore = await LeakedHelpers.running()
        let dotEnv = DotEnv.load(repo)
        if sources.contains(.bigFish) && BigFishSourceOptions.testAccount(dotEnv: dotEnv) == nil {
            ui.warning("The owned Big Fish suite will skip every game: .env has no Big Fish test account.",
                       next: "Set \(BigFishSourceOptions.accountKeys.joined(separator: " and ")) in .env, or test the free trials with --source big-fish-trial.")
        }
        // The prebuilt wrapps --refresh-wrapp reuses are disk builds; the
        // other sources' suites always build their own.
        if refresh != .full && sources.contains(.disk) {
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

        let sizes = IntegrationSizes(testResults: repo.testResults)
        var env = [
            "TEST_RUNNER_REPO_ROOT": repo.root.path,
            "TEST_RUNNER_\(InstallersStore.environmentVariable)": repo.installers.root.path,
            "TEST_RUNNER_PROGRESS_PATH": progressFile.path,
            "TEST_RUNNER_WRAPPS_DIR": wrappsDir.path,
            "TEST_RUNNER_SIZE_ESTIMATES_PATH": sizes.url.path,
            "TEST_RUNNER_BUILD_CONCURRENCY": "\(buildConcurrency)",
            "TEST_RUNNER_DISK_MARGIN_GB": "\(diskMargin)",
        ]
        // Asked for by name, so missing ISOs are a failure, not a skip that
        // would report a pass having tested nothing.
        if sources.contains(.disk) { env["TEST_RUNNER_REQUIRE_INSTALLERS"] = "1" }
        // `--bundle`'s bundles, for the test host and the WrappPuppeteer it starts.
        if let extras = ProcessInfo.processInfo.environment[ExtraBundles.environmentVariable] {
            env["TEST_RUNNER_\(ExtraBundles.environmentVariable)"] = extras
        }
        if !requested.isEmpty { env["TEST_RUNNER_TEST_GAMES"] = requested.map(\.slug).joined(separator: ",") }
        if refresh != .full { env["TEST_RUNNER_SKIP_BUILD"] = "1" }
        if ignoreLoad { env["TEST_RUNNER_IGNORE_LOAD"] = "1" }
        if keepFailedBuilds { env["TEST_RUNNER_SECOND_CHANCE_KEEP_FAILED_BUILD"] = "1" }
        env.merge(Self.recordingEnvironment(keepRecordings: keepRecordings)) { _, new in new }
        if keepRecordings && vm != nil {
            ui.warning("--keep-recordings keeps nothing from a VM: WrappPuppeteer doesn't record the screen there.")
        }
        env.merge(Self.hostEnvironment(dotEnv: dotEnv)) { _, new in new }
        env.merge(Self.bigFishEnvironment(dotEnv: dotEnv, sources: sources)) { _, new in new }
        // The test launches each game in the VM instead (VMPuppetRunner).
        if let vm {
            env.merge(vm.testEnvironment) { _, new in new }
            ui.info("Games launch in VM \(vm.name) (\(vm.target)); they're still built on this Mac.")
        }
        let environment = env

        // The Her suite reports a game once per download, as the slug for the
        // Windows one and "<slug> mac" for the Mac one (HerDownloadCase.label).
        let board = GameBoard(rows: entries.flatMap { entry -> [(source: String, slug: String, engine: String)] in
            guard entry.source == IntegrationSource.herDownload.rawValue else {
                return [(source: entry.source, slug: entry.game.slug, engine: entry.game.engine)]
            }
            return Games.herDownloads(for: entry.game, repo: repo).map { download in
                let label = download.format == "mac" ? "\(entry.game.slug) mac" : entry.game.slug
                return (source: entry.source, slug: label, engine: entry.game.engine)
            }
        })
        let showSource = sources != [.disk]
        let live = ui.isLive
        let following = follower.follow { record in
            // Why a game was held back: the Mac's load, or its screen.
            if record.event == "load" || record.event == "screen", let message = record.message {
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
            table: { Self.gameTable(board, showSource: showSource) },
            run: { sink in
                try await xcode.runTests(selection: Self.integrationSelection(sources), environment: environment, resultBundle: bundle, sink: sink)
            }
        )
        for record in follower.poll() { board.apply(record) }
        do {
            try sizes.record(board.peakBytes)
        } catch {
            ui.warning("Couldn't record how much disk each game's build took in \(sizes.url.path): \(error.localizedDescription)")
        }
        let table = Self.gameTable(board, showSource: showSource)
        await ui.table(headers: table.headers, rows: table.rows)
        let warned = board.rows.filter { !$0.warnings.isEmpty }
        if !warned.isEmpty {
            let lines = warned.flatMap { row in row.warnings.map { "\(row.slug)\(showSource ? " (\(row.source))" : ""): \($0)" } }
            let listed = lines.map { "  ▸ \($0)" }.joined(separator: "\n")
            ui.warning("Passing or not, these games had something to look into:\n\(listed)")
        }
        if board.hasOverloadedGames {
            ui.warning("Some games weren't tested: the Mac was heavily loaded, so Wine would have taken minutes to start, or never started.",
                       next: "Quit the busy programs and run those games again, or pass --ignore-load to test them anyway.")
        }
        if board.hasLockedGames {
            ui.warning("Some games weren't tested: the screen was locked or the display asleep, so they couldn't come to the front.",
                       next: "Keep the Mac awake and unlocked for the run (caffeinate -d), and run those games again.")
        }
        await LeakedHelpers.endStarted(since: helpersBefore, ui: ui)
        return TestRun(name: "Integration", status: status, bundle: bundle, summary: await TestReports.summary(of: bundle), games: board.rows)
    }

    /// Build and launch times are the game's own: the time it spent waiting
    /// for others is in Waited, shown once any game waited.
    static func gameTable(_ board: GameBoard, showSource: Bool) -> (headers: [String], rows: [StyledTableRow]) {
        gameTable(board.rows, showSource: showSource)
    }

    static func gameTable(_ gameRows: [GameBoard.Row], showSource: Bool) -> (headers: [String], rows: [StyledTableRow]) {
        let showWaited = gameRows.contains { ($0.queuedSeconds ?? 0) >= 1 }
        let showDisk = gameRows.contains { $0.peakBytes != nil }
        let seconds: (Double?) -> TableCellStyle = { .muted($0.map(DurationText.text) ?? "") }
        let rows: [StyledTableRow] = gameRows.map { game in
            (showSource ? [.muted(game.source)] : [])
                + [.plain(game.slug), .muted(game.engine), Self.statusCell(game.status), seconds(game.buildSeconds), seconds(game.launchSeconds)]
                + (showWaited ? [seconds(game.queuedSeconds)] : [])
                + (showDisk ? [.muted(game.peakBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")] : [])
        }
        let headers = (showSource ? ["Source"] : []) + ["Game", "Engine", "Result", "Build", "Launch"]
            + (showWaited ? ["Waited"] : []) + (showDisk ? ["Disk"] : [])
        return (headers, rows)
    }

    private static func statusCell(_ status: String) -> TableCellStyle {
        switch status {
        case "passed": .success(status)
        case "failed", ShardReport.infrastructureStatus, ShardReport.unrunnableStatus: .danger(status)
        case "overloaded", "locked": .warning(status)
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
    /// Codable: a shard writes its rows for the coordinator (`ShardResult`).
    struct Row: Sendable, Codable, Equatable {
        let source: String
        let slug: String
        let engine: String
        var status: String
        var stage: String?
        var seconds: Double?
        var buildSeconds: Double?
        var launchSeconds: Double?
        var queuedSeconds: Double?
        var peakBytes: Int64?
        var warnings: [String] = []
    }

    private let lock = NSLock()
    /// Rows are keyed by source and slug: a game tested from disk and from
    /// Steam is two rows.
    private var rowsByKey: [String: Row]
    private var order: [String]
    /// The games under way, in the order they started: several build at once.
    private var running: [String] = []

    private static func key(_ source: String, _ slug: String) -> String { "\(source)/\(slug)" }

    convenience init(games: [CatalogGame]) {
        self.init(entries: games.map { (source: "disk", game: $0) })
    }

    convenience init(entries: [(source: String, game: CatalogGame)]) {
        self.init(rows: entries.map { (source: $0.source, slug: $0.game.slug, engine: $0.game.engine) })
    }

    /// Rows named other than by the game's slug, such as a Her download's
    /// `<slug> mac`, which must match what the suite reports.
    init(rows: [(source: String, slug: String, engine: String)]) {
        order = rows.map { Self.key($0.source, $0.slug) }
        rowsByKey = Dictionary(rows.map {
            (Self.key($0.source, $0.slug), Row(source: $0.source, slug: $0.slug, engine: $0.engine, status: "pending"))
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Apply a record; returns a plain line describing it, for non-live output.
    @discardableResult
    func apply(_ record: ProgressRecord) -> String? {
        lock.withLock {
            switch record.event {
            case "game":
                guard let slug = record.slug else { return nil }
                let source = record.source ?? "disk"
                let key = Self.key(source, slug)
                if rowsByKey[key] == nil { order.append(key) }  // a row the suite added, e.g. a second launch mode
                var row = rowsByKey[key] ?? Row(source: source, slug: slug, engine: "", status: "pending")
                switch record.phase {
                case "started":
                    row.status = "running"
                    row.stage = "starting"
                    running.removeAll { $0 == key }
                    running.append(key)
                case "finished":
                    row.status = record.result ?? "failed"
                    row.seconds = record.seconds
                    row.buildSeconds = record.buildSeconds
                    row.launchSeconds = record.launchSeconds
                    row.queuedSeconds = record.queuedSeconds
                    row.peakBytes = record.peakBytes
                    row.warnings = record.warnings ?? []
                    row.stage = nil
                    running.removeAll { $0 == key }
                default:
                    row.stage = record.phase
                }
                rowsByKey[key] = row
                let label = source == "disk" ? slug : "\(slug) (\(source))"
                return "▸ \(label): \(record.phase ?? "")\(record.result.map { " (\($0))" } ?? "")"
            case "stage":
                // A build's stage names its game; one that doesn't is the
                // latest game's, as when only one ran at a time.
                let key = record.slug.map { Self.key(record.source ?? "disk", $0) } ?? running.last
                guard let key, let text = record.text, rowsByKey[key]?.status == "running" else { return nil }
                rowsByKey[key]?.stage = text
                return nil
            default:
                return nil
            }
        }
    }

    /// In the catalogue's order, which never changes: rows don't jump
    /// around as games finish. The status line names the running games even
    /// when a short window trims the table.
    var rows: [Row] {
        lock.withLock { order.compactMap { rowsByKey[$0] } }
    }

    var fraction: Double {
        lock.withLock {
            guard !order.isEmpty else { return 0 }
            let done = rowsByKey.values.filter { !["pending", "running"].contains($0.status) }.count
            return Double(done) / Double(order.count)
        }
    }

    var statusLine: String {
        lock.withLock {
            let done = rowsByKey.values.filter { !["pending", "running"].contains($0.status) }.count
            var line = "\(done)/\(order.count) games"
            let rows = running.compactMap { rowsByKey[$0] }
            // The one launching, which has the screen, else the latest.
            guard let focus = rows.first(where: { $0.stage == "launching" }) ?? rows.last else { return line }
            line += " · \(Self.label(focus)): \(focus.stage ?? "running")"
            let others = rows.filter { $0.source != focus.source || $0.slug != focus.slug }
            if !others.isEmpty {
                line += " · also running: \(others.map(Self.label).joined(separator: ", "))"
            }
            return line
        }
    }

    private static func label(_ row: Row) -> String {
        row.source == "disk" ? row.slug : "\(row.slug) (\(row.source))"
    }

    /// The most disk each game's build took, by `source/slug`, for the games
    /// that said.
    var peakBytes: [String: Int64] {
        lock.withLock {
            rowsByKey.compactMapValues(\.peakBytes)
        }
    }

    var hasOverloadedGames: Bool {
        lock.withLock { rowsByKey.values.contains { $0.status == "overloaded" } }
    }

    var hasLockedGames: Bool {
        lock.withLock { rowsByKey.values.contains { $0.status == "locked" } }
    }
}
