import ArgumentParser
import Foundation
import GameCatalog
import Noora

struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run the tests. With no subcommand: unit tests, then integration tests.",
        discussion: """
        Bare `sc test` runs everything, including the integration suite, which \
        installs every game for real and takes hours. `sc test unit` is the fast loop.
        """,
        subcommands: [TestAllCommand.self, TestUnitCommand.self, TestIntegrationCommand.self],
        defaultSubcommand: TestAllCommand.self
    )
}

struct IntegrationOptions: ParsableArguments {
    @Option(help: ArgumentHelp(
        "How to get each game's wrapp: full (build it — what the suite tests), template, or skip.",
        discussion: "template and skip launch-test the wrapps already in the wrapps dir (template refreshes their WrappTemplate first); a missing wrapp fails."
    ))
    var refreshWrapp: WrappRefresh = .full

    @OptionGroup var wrapps: WrappsDirOptions
}

struct ReportOptions: ParsableArguments {
    @Option(help: "When to open the HTML report: failures, always or never.")
    var openReport: ReportPolicy = .failures
}

struct TestAllCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "all",
        abstract: "Unit tests, then integration tests (hours: real installs of every game)."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var appBuild: AppBuildOptions
    @OptionGroup var integration: IntegrationOptions
    @OptionGroup var report: ReportOptions

    @Argument(help: "Limit the integration half to these games (slugs).")
    var games: [String] = []

    func run() async throws {
        let session = try Session.start(global)
        let games = try TestCommandSupport.resolve(self.games, ui: session.ui)
        try await GUISession.ensure(session, need: .screen)
        try TestCommandSupport.requireTools()
        let stamp = UI.timestamp()
        let runner = TestRunner(session: session)
        try await runner.xcode.ensureTestBuild(appBuild)
        let unit = try await runner.unit(stamp: stamp)
        let integrationRun = try await runner.integration(
            games: games, refresh: integration.refreshWrapp, wrappsDir: integration.wrapps.resolve(session.repo), stamp: stamp
        )
        try await TestCommandSupport.finish([unit, integrationRun], stamp: stamp, policy: report.openReport, session: session)
    }
}

struct TestUnitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unit",
        abstract: "Run the unit tests (seconds), plus sc's own tests.",
        discussion: "Every suite except the integration and exiftool ones — a new suite runs by default."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var appBuild: AppBuildOptions
    @OptionGroup var report: ReportOptions

    func run() async throws {
        let session = try Session.start(global)
        try TestCommandSupport.requireTools()
        let stamp = UI.timestamp()
        let runner = TestRunner(session: session)
        try await runner.xcode.ensureTestBuild(appBuild)
        let unit = try await runner.unit(stamp: stamp)
        let toolStatus = try await TestCommandSupport.runToolTests(session)
        try await TestCommandSupport.finish([unit], stamp: stamp, policy: report.openReport, session: session, extraFailure: toolStatus)
    }
}

struct TestIntegrationCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "integration",
        abstract: "Install, launch and quit games for real (minutes per game).",
        discussion: "Needs the games' disk images in installers/<slug>/. Missing images fail rather than skip."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var appBuild: AppBuildOptions
    @OptionGroup var integration: IntegrationOptions
    @OptionGroup var report: ReportOptions

    @Argument(help: "The games to test (slugs). Default: all of them.")
    var games: [String] = []

    func run() async throws {
        let session = try Session.start(global)
        let games = try TestCommandSupport.resolve(self.games, ui: session.ui)
        try await GUISession.ensure(session, need: .screen)
        try TestCommandSupport.requireTools()
        let stamp = UI.timestamp()
        let runner = TestRunner(session: session)
        try await runner.xcode.ensureTestBuild(appBuild)
        let run = try await runner.integration(
            games: games, refresh: integration.refreshWrapp, wrappsDir: integration.wrapps.resolve(session.repo), stamp: stamp
        )
        try await TestCommandSupport.finish([run], stamp: stamp, policy: report.openReport, session: session)
    }
}

enum TestCommandSupport {
    static func resolve(_ slugs: [String], ui: UI) throws -> [CatalogGame] {
        try slugs.map { slug in
            guard let game = Catalog.game(slug: slug) else {
                var hints: [String] = []
                if let guess = Games.closest(to: slug) { hints.append("Did you mean \(guess.slug)?") }
                throw SCError("No game called '\(slug)'.", hints: hints)
            }
            return game
        }
    }

    static func requireTools() throws {
        try Proc.require("xcbeautify", brew: "xcbeautify")
        try Proc.require("xchtmlreport", brew: "xctest-html-report")
    }

    /// sc's own Swift tests (Tools/sc).
    static func runToolTests(_ session: Session) async throws -> Int32 {
        let package = session.repo.root.appendingPathComponent("Tools/sc")
        do {
            try await session.ui.logStep("sc's own tests", log: "test-sc", success: "sc's own tests passed") { sink in
                try await Proc.stream("swift", ["test", "--package-path", package.path], cwd: session.repo.root) { await sink.line($0) }
            }
            return 0
        } catch let error as SCError where error.alreadyReported {
            return error.exitCode
        }
    }

    /// Totals, the HTML report, and the verdict (a non-zero exit when anything failed).
    static func finish(_ runs: [TestRun], stamp: String, policy: ReportPolicy, session: Session, extraFailure: Int32 = 0) async throws {
        let ui = session.ui
        let reportDir = session.repo.testResults.appendingPathComponent(stamp)
        let report = await TestReports.writeHTML(for: runs.map(\.bundle), into: reportDir)
        let failed = runs.contains { $0.status != 0 } || extraFailure != 0

        var totals: [String] = []
        for run in runs {
            if let summary = run.summary {
                var parts = ["\(summary.passedTests ?? 0) passed"]
                if let failed = summary.failedTests, failed > 0 { parts.append("\(failed) failed") }
                if let skipped = summary.skippedTests, skipped > 0 { parts.append("\(skipped) skipped") }
                totals.append("\(run.name): \(parts.joined(separator: ", "))\(summary.seconds.map { String(format: " in %.0fs", $0) } ?? "")")
            } else {
                totals.append("\(run.name): \(run.status == 0 ? "passed" : "failed (exit \(run.status))")")
            }
        }

        if let report, policy.shouldOpen(failed: failed) {
            _ = try? await Proc.collect("/usr/bin/open", [report.path])
        }
        let reportLine = report.map { "Report: \(session.repo.display($0))" }

        guard failed else {
            ui.success(TerminalTextBuilder.text(totals.joined(separator: "\n")), takeaways: reportLine.map { [TerminalTextBuilder.text($0)] } ?? [])
            return
        }
        let failures = runs.flatMap { $0.summary?.testFailures ?? [] }
        var hints = failures.prefix(10).map { "\($0.testName)\($0.failureText.map { ": \($0)" } ?? "")" }
        if failures.count > 10 { hints.append("… and \(failures.count - 10) more") }
        if let reportLine { hints.append(reportLine) }
        let firstFailure: Int32 = runs.first(where: { $0.status != 0 }).map(\.status) ?? extraFailure
        throw SCError(totals.joined(separator: "\n"), hints: hints, exitCode: firstFailure == 0 ? 1 : firstFailure)
    }
}

/// Building a `TerminalText` from a runtime string.
enum TerminalTextBuilder {
    static func text(_ string: String) -> TerminalText { TerminalText(stringLiteral: string) }
}
