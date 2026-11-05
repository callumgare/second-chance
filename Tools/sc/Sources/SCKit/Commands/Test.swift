import ArgumentParser
import Foundation
import Noora

struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run the tests: name which.",
        discussion: """
        `sc test unit` runs the unit tests, the fast loop (or only the suites named). \
        `sc test integration` installs games for real and takes hours for all of them; \
        `sc test all` runs both. A bare `sc test` runs nothing: it shows this.
        """,
        subcommands: [TestAllCommand.self, TestUnitCommand.self, TestIntegrationCommand.self]
    )

    /// Bare `sc test`: this help, and a failure, so a script that still runs
    /// it expecting the unit tests doesn't take nothing for a pass.
    func run() async throws {
        FileHandle.standardError.write(Data((Self.helpMessage() + "\n").utf8))
        throw ExitCode(64)
    }
}

struct IntegrationOptions: ParsableArguments {
    @Option(help: ArgumentHelp(
        "How to get each game's wrapp: full (build it — what the suite tests), template, or skip.",
        discussion: "template and skip launch-test the wrapps already in the wrapps dir (template refreshes their WrappTemplate first); a missing wrapp fails."
    ))
    var refreshWrapp: WrappRefresh = .full

    @Flag(help: ArgumentHelp(
        "Test each game even when the Mac is heavily loaded.",
        discussion: "Normally a game is reported as overloaded, not tested, when other programs keep all but one performance core busy for a minute: "
            + "Wine then takes minutes to start, or never does, so the result would say more about the load than the game."
    ))
    var ignoreLoad = false

    @Flag(name: .customLong("keep-failed-builds"),
          help: ArgumentHelp("Keep the folder of each build that fails, for a look, logging where it is.",
                             discussion: "Each is the build's working folder in the temporary folder, gigabytes for a Wine game, left until removed by hand."))
    var keepFailedBuilds = false

    @Option(help: ArgumentHelp(
        "How many games to build at once. Games still launch one at a time. Defaults to one per four performance cores.",
        discussion: "Builds also wait for disk: each reserves what its game's build took last time (or an estimate), "
            + "and keeps it until its wrapp is deleted after its launch (docs/testing.md#building-games-side-by-side).",
        valueName: "count"
    ))
    var buildConcurrency: Int?

    @Option(help: ArgumentHelp(
        "Disk to leave free while games build, in GB.",
        valueName: "GB"
    ))
    var diskMargin: Double = 10

    @Option(help: ArgumentHelp(
        "Which builds to test: disk, steam, her-download, big-fish, big-fish-trial, download, or all — comma-separated. Default: disk.",
        discussion: "steam builds each game from Steam with the saved Steam sign-in (docs/steam.md) and skips games the account doesn't own. "
            + "her-download builds each game from every installers/<slug>/her-download*.exe or .dmg (docs/her-download.md). "
            + "big-fish builds each game Big Fish sells, signed in with the test account in .env (BIG_FISH_EMAIL, BIG_FISH_PASSWORD), "
            + "and skips games the account doesn't own; big-fish-trial builds each one's free trial, signed out (docs/big-fish.md). "
            + "download builds each program with a download edition from the URLs its bundle names (docs/wrapp-build.md#the-download-source). "
            + "All of them always build, whatever --refresh-wrapp says.",
        valueName: "sources"
    ))
    var source = "disk"

    @Option(help: ArgumentHelp(
        "Launch each game in this tart VM instead of on this Mac.",
        discussion: "The wrapp is still built here; the test copies it and WrappPuppeteer into the VM and runs the launch-and-quit there. "
            + "A stopped VM is started headless and stopped afterwards. "
            + "Games that draw with Direct3D can't render in a VM, so their launch is skipped (docs/testing.md#testing-in-a-vm).",
        valueName: "name"
    ))
    var vm: String?

    @Flag(help: ArgumentHelp(
        "Keep the screen recording of every launch, passed or not, as an attachment in the results.",
        discussion: "Normally a launch's recording is kept only when it fails or WrappPuppeteer warns, as one whose splash screens "
            + "went unrecognised does. Name the games to test to keep only theirs. Each recording runs for up to \(IntegrationOptions.keptRecordingLimit) s "
            + "rather than 2 minutes, to take in a slow start (docs/testing.md#wrapppuppeteer)."
    ))
    var keepRecordings = false

    /// How long a kept recording may run, in seconds.
    static let keptRecordingLimit = 300

    @OptionGroup var wrapps: WrappsDirOptions

    /// The sources `--source` names, in their canonical order.
    var sources: [IntegrationSource] { (try? Self.parseSources(source)) ?? [.disk] }

    /// What this Mac's GUI session must allow. Builds open windows here
    /// either way; only a game launched here needs to see and click the
    /// screen, so with --vm a locked screen is fine.
    var screenNeed: GUISession.Need { vm == nil ? .screen : .windows }

    /// Run `body` with the VM `--vm` names prepared (nil without one), then
    /// stop the VM if sc started it, whether `body` succeeds or throws.
    func withVM<T>(_ session: Session, _ body: (TestVM.Prepared?) async throws -> T) async throws -> T {
        guard let vm else { return try await body(nil) }
        let testVM = TestVM(name: vm, session: session)
        let prepared = try await testVM.prepare()
        do {
            let result = try await body(prepared)
            await testVM.finish(prepared)
            return result
        } catch {
            await testVM.finish(prepared)
            throw error
        }
    }

    func validate() throws {
        _ = try Self.parseSources(source)
        guard (buildConcurrency ?? 1) >= 1 else { throw ValidationError("--build-concurrency must be at least 1.") }
        guard diskMargin >= 0 else { throw ValidationError("--disk-margin can't be negative.") }
    }

    /// `--build-concurrency`, or one build per four performance cores of the
    /// Mac the tests run on: on an 8-performance-core Mac, two builds cut a
    /// run's time by a quarter, and more saved little while slowing launches
    /// (docs/testing.md#how-many-to-build-at-once).
    var resolvedBuildConcurrency: Int {
        buildConcurrency ?? Self.defaultBuildConcurrency(fastCores: Self.fastCoreCount)
    }

    static func defaultBuildConcurrency(fastCores: Int) -> Int {
        max(1, fastCores / 4)
    }

    /// Performance cores, or all physical cores where there are no levels
    /// (Intel Macs) — as `SystemLoad.fastCoreCount` counts them.
    static var fastCoreCount: Int {
        for name in ["hw.perflevel0.physicalcpu", "hw.physicalcpu"] {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 {
                return Int(value)
            }
        }
        return ProcessInfo.processInfo.activeProcessorCount
    }

    static func parseSources(_ value: String) throws -> [IntegrationSource] {
        let names = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if names.contains("all") { return IntegrationSource.allCases }
        var sources = Set<IntegrationSource>()
        for name in names {
            guard let source = IntegrationSource(rawValue: name) else {
                let known = IntegrationSource.allCases.map(\.rawValue) + ["all"]
                let guess = known.min { Games.distance(name, $0) < Games.distance(name, $1) }
                throw ValidationError("Unknown source '\(name)'.\(guess.map { " Did you mean '\($0)'?" } ?? "") Sources: \(known.joined(separator: ", ")).")
            }
            sources.insert(source)
        }
        guard !sources.isEmpty else { throw ValidationError("Give at least one source: disk, steam, her-download, big-fish, big-fish-trial or all.") }
        return IntegrationSource.allCases.filter(sources.contains)
    }
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
        try await GUISession.ensure(session, need: integration.screenNeed)
        try TestCommandSupport.requireTools()
        let stamp = UI.timestamp()
        let runner = TestRunner(session: session)
        try await runner.xcode.ensureTestBuild(appBuild)
        let unit = try await runner.unit(stamp: stamp)
        let integrationRun = try await integration.withVM(session) { vm in
            try await runner.integration(
                games: games, sources: integration.sources, refresh: integration.refreshWrapp, wrappsDir: integration.wrapps.resolve(session.repo),
                ignoreLoad: integration.ignoreLoad, keepFailedBuilds: integration.keepFailedBuilds,
                buildConcurrency: integration.resolvedBuildConcurrency, diskMargin: integration.diskMargin,
                keepRecordings: integration.keepRecordings, vm: vm, stamp: stamp
            )
        }
        try await TestCommandSupport.finish([unit, integrationRun], stamp: stamp, policy: report.openReport, session: session)
    }
}

struct TestUnitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unit",
        abstract: "Run the unit tests (seconds): the app's, the shared package's and sc's own.",
        discussion: """
            Every suite except the integration ones — a new suite runs by default. Name suites to run only \
            those: each is found where it's declared, and the app is built for testing only when one of them \
            is the app's.
            """
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var appBuild: AppBuildOptions
    @OptionGroup var report: ReportOptions

    @Argument(help: ArgumentHelp(
        "Suites to run instead of all of them: a suite's type, or one of its tests.",
        discussion: "DocsTableTests runs that suite; DocsTableTests/aTest() one test in it. Each runs wherever it's declared: "
            + "the app's tests, a local package's or sc's own.",
        valueName: "suite"
    ))
    var suites: [String] = []

    func run() async throws {
        let session = try Session.start(global)
        try TestCommandSupport.requireTools()
        let stamp = UI.timestamp()
        let runner = TestRunner(session: session)
        let selection = try suites.isEmpty ? nil : UnitTestSelection.locate(
            suites, root: session.repo.root, packages: TestCommandSupport.testedPackages, integrationSuites: TestRunner.unitExclusions)
        var runs: [TestRun] = []
        if selection.map({ !$0.app.isEmpty }) ?? true {
            try await runner.xcode.ensureTestBuild(appBuild)
            runs.append(try await runner.unit(stamp: stamp, only: selection?.app))
        }
        let packageStatus = try await TestCommandSupport.runPackageTests(session, only: selection?.packages)
        let toolStatus = try await TestCommandSupport.runToolTests(session, only: selection?.tool)
        try await TestCommandSupport.finish(runs, stamp: stamp, policy: report.openReport, session: session,
                                            extraFailure: packageStatus != 0 ? packageStatus : toolStatus)
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
        try await GUISession.ensure(session, need: integration.screenNeed)
        try TestCommandSupport.requireTools()
        let stamp = UI.timestamp()
        let runner = TestRunner(session: session)
        try await runner.xcode.ensureTestBuild(appBuild)
        let run = try await integration.withVM(session) { vm in
            try await runner.integration(
                games: games, sources: integration.sources, refresh: integration.refreshWrapp, wrappsDir: integration.wrapps.resolve(session.repo),
                ignoreLoad: integration.ignoreLoad, keepFailedBuilds: integration.keepFailedBuilds,
                buildConcurrency: integration.resolvedBuildConcurrency, diskMargin: integration.diskMargin,
                keepRecordings: integration.keepRecordings, vm: vm, stamp: stamp
            )
        }
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
        try Proc.require("xchtmlreport", brew: "xctesthtmlreport")
    }

    /// sc's own Swift tests (Tools/sc).
    /// The local packages that have tests of their own: what needs neither
    /// app, run by SwiftPM with no Xcode build.
    static let testedPackages = ["WrappKit", "SecondChanceKit", "PuppeteerCore", "WrappBuilder", "WrappBuilderCLI", "Modules/wine", "Modules/nancy-drew"]

    /// Each of `testedPackages`' tests, or only the suites `only` names in
    /// each package it has any for; the first failure's status, or 0.
    static func runPackageTests(_ session: Session, only: [String: [String]]? = nil) async throws -> Int32 {
        var status: Int32 = 0
        for name in testedPackages {
            let filters = only?[name]
            if only != nil && filters == nil { continue }
            let package = session.repo.root.appendingPathComponent("Packages/\(name)")
            do {
                try await session.ui.logStep("\(name)'s tests", log: "test-\(name.lowercased())", success: "\(name)'s tests passed") { sink in
                    try await Proc.stream("swift", ["test", "--package-path", package.path] + filterArguments(filters), cwd: session.repo.root) {
                        await sink.line($0)
                    }
                }
            } catch let error as SCError where error.alreadyReported {
                if status == 0 { status = error.exitCode }
            }
        }
        return status
    }

    /// sc's own tests, or only the suites `only` names (none: not run).
    static func runToolTests(_ session: Session, only: [String]? = nil) async throws -> Int32 {
        if let only, only.isEmpty { return 0 }
        let package = session.repo.root.appendingPathComponent("Tools/sc")
        do {
            try await session.ui.logStep("sc's own tests", log: "test-sc", success: "sc's own tests passed") { sink in
                try await Proc.stream("swift", ["test", "--package-path", package.path] + filterArguments(only), cwd: session.repo.root) {
                    await sink.line($0)
                }
            }
            return 0
        } catch let error as SCError where error.alreadyReported {
            return error.exitCode
        }
    }

    /// `swift test`'s `--filter` for each of `suites`; nothing for all of them.
    static func filterArguments(_ suites: [String]?) -> [String] {
        (suites ?? []).flatMap { ["--filter", $0] }
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
            // Only package suites were run: their steps have said so.
            if totals.isEmpty { totals.append("The suites asked for passed") }
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
