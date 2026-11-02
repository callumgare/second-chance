//
//  IntegrationGameRun.swift
//  SecondChanceTests
//
//  One game's integration test, whatever its source: the checks before it,
//  the build, the assertions every source shares, and the launch. Each suite
//  supplies what differs — how to start its build and what else to check.

import Foundation
import Testing
@testable import SecondChance
@testable import SecondChanceKit
import GameCatalog

struct IntegrationGameRun {
    let game: GameInfo
    /// The row `sc` shows for it: the slug, or for a Her Mac download "<slug> mac".
    let label: String
    /// Which suite: `disk`, `her-download`, `steam`, `big-fish` or `big-fish-trial`.
    let source: String
    let progress: ProgressFileWriter?

    /// What a suite tells the run about its build.
    struct Build {
        /// The engine the build should route the game to.
        let expectedEngine: GameInfo.GameEngine
        /// The files it installs from, to estimate the disk it needs before
        /// it has been measured; none for a Steam game.
        var installers: [URL] = []
        /// The input for its view model, given the test's output directory.
        let makeInput: @MainActor (URL, WrappBuildViewModel) -> WrappBuildInput
        /// Starts the build: `build(from: .disk)` and the like.
        let start: @MainActor (WrappBuildViewModel) async -> Void
    }

    /// Runs the whole test: waits for its turn to build (`IntegrationStages`),
    /// builds and checks the wrapp, then waits for its turn on screen and
    /// launches it.
    ///
    /// - `prebuiltWrapp`: a wrapp to launch instead of building one
    ///   (`SKIP_BUILD`); the build and its checks are skipped.
    /// - `prepare`: the build to run; nil holds the game back without
    ///   building, having set the outcome's reason.
    /// - `afterBuild`: false ends the test once the build is over, before
    ///   any assertion, having set the outcome's reason.
    /// - `check`: the suite's own assertions on the build it made.
    func run(
        prebuiltWrapp: URL? = nil,
        prepare: (GameOutcome) async throws -> Build?,
        afterBuild: (RecordingEventSubscriber, GameOutcome) -> Bool = { _, _ in true },
        check: (RecordingEventSubscriber, URL, GameOutcome) async throws -> Void
    ) async throws {
        // The finished line's result agrees with this test's: any failed
        // expectation or thrown error makes it "failed".
        let outcome = GameOutcome(slug: label, source: source, progress: progress)
        defer { outcome.finish() }

        let wrapp: URL
        // The build's place in the gate, given back once its output is gone:
        // declared first, so it is released after the output is removed.
        var ticket: BuildGate.Ticket?
        defer {
            if let ticket { Task { await IntegrationStages.build.release(ticket) } }
        }
        // On every path out, including a build or check that throws: an output
        // directory left behind holds a whole wrapp.
        var outputDir: URL?
        defer { if let outputDir { Self.removeOutputDir(outputDir) } }

        if let prebuiltWrapp {
            wrapp = prebuiltWrapp
        } else {
            guard let build = try await prepare(outcome) else { return }

            outcome.phase("waiting to build")
            let bytes = IntegrationStages.reservation(source: source, label: label, installers: build.installers)
            do {
                ticket = try await outcome.timed(.queued) { try await IntegrationStages.build.admit(bytes: bytes) }
            } catch {
                outcome.expect(false, "Not building \(label): \(error)")
                return
            }
            guard await loadAllows(outcome) else { return }

            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-\(source)-integration-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            outputDir = dir
            let built = try await outcome.timed(.build) {
                try await buildWrapp(build, into: dir, ticket: ticket, outcome: outcome, afterBuild: afterBuild, check: check)
            }
            if let ticket { await IntegrationStages.build.finishedBuilding(ticket) }
            guard let built else { return }
            wrapp = built
        }

        guard WrappInfo.wrappPuppeteerBundle() != nil else {
            Attachment.record("WrappPuppeteer not built — skipped the launch", named: "launch-skipped-\(label).txt")
            await InstalledGameCheck.run(wrapp: wrapp, game: game, outcome: outcome)
            outcome.completed = true
            return
        }
        // A VM can't render Direct3D; the build above was still tested.
        if let reason = VMTarget.launchSkipReason(wrappURL: wrapp) {
            outcome.skipped = "\(game.title) \(reason)"
            await InstalledGameCheck.run(wrapp: wrapp, game: game, outcome: outcome)
            outcome.completed = true
            return
        }

        outcome.phase("waiting to launch")
        let waitingSince = Date()
        try await IntegrationStages.launch.withLock {
            outcome.add(.queued, Date().timeIntervalSince(waitingSince))
            guard screenAllows(outcome), await loadAllows(outcome) else { return }
            outcome.phase("launching")
            let exitCode = try await outcome.timed(.launch) {
                try await AppPuppetRunner.run(wrappURL: wrapp, game: game) { outcome.warn($0) }
            }
            outcome.puppeteerExit = exitCode
            outcome.expect(exitCode == 0, "WrappPuppeteer exited with \(exitCode) for \(label)")
            // Again, quitting through the game's Quit menu item (⌘⌥Q), which
            // goes through Wine rather than the game: it has hung for good
            // when the game's process had no Dock icon of its own. Not in a
            // VM, whose runner launches only the one way.
            if exitCode == 0, VMTarget.current == nil {
                outcome.phase("relaunching to quit from the menu")
                let menuExit = try await outcome.timed(.launch) {
                    try await AppPuppetRunner.run(wrappURL: wrapp, game: game, quitFromMenu: true) { outcome.warn($0) }
                }
                outcome.expect(menuExit == 0, "WrappPuppeteer exited with \(menuExit) quitting \(label) from its menu")
            }
            await InstalledGameCheck.run(wrapp: wrapp, game: game, outcome: outcome)
            outcome.completed = true
        }
    }

    // MARK: - Whether the Mac can test it

    /// Whether the Mac is calm enough to build or launch the game fairly: one
    /// too busy for Wine to start would make this a test of the load, not the
    /// game (see `LoadGate`). Checked before the build and again before the
    /// launch. Other games' builds in this run don't count as load.
    private func loadAllows(_ outcome: GameOutcome) async -> Bool {
        if LoadGate.ignoringLoad {
            if let load = LoadGate.heavyReadingNow() {
                progress?.write(["event": "load", "message": "Testing \(label) on a heavily loaded Mac (--ignore-load): \(load.summary)."])
            }
            return true
        }
        guard let load = await LoadGate.overloadedReading() else { return true }
        let message = "Not testing \(label): the Mac is heavily loaded — \(load.summary). "
            + "Wine would take minutes to start, or never start; quit the busy programs, or pass --ignore-load to test anyway."
        progress?.write(["event": "load", "message": message])
        outcome.overloaded = true
        Issue.record(Comment(rawValue: message))
        return false
    }

    /// Whether the game can come to the front: launched while the screen is
    /// locked or the display asleep, it never can, so WrappPuppeteer would
    /// only time out waiting for it. Checked just before the launch; the
    /// build doesn't need the screen.
    private func screenAllows(_ outcome: GameOutcome) -> Bool {
        guard let reason = VMTarget.screenBlockedReason() else { return true }
        let message = "Not launching \(label): \(reason), so the game couldn't come to the front. Keep the Mac awake and unlocked for the run (caffeinate -d)."
        progress?.write(["event": "screen", "message": message])
        outcome.locked = true
        Issue.record(Comment(rawValue: message))
        return false
    }

    // MARK: - The build

    /// Builds the wrapp through the real view model and checks it, returning
    /// it, or nil when `afterBuild` ends the test.
    private func buildWrapp(
        _ build: Build,
        into outputDir: URL,
        ticket: BuildGate.Ticket?,
        outcome: GameOutcome,
        afterBuild: (RecordingEventSubscriber, GameOutcome) -> Bool,
        check: (RecordingEventSubscriber, URL, GameOutcome) async throws -> Void
    ) async throws -> URL? {
        // A bus of the build's own, so a build running alongside it can't
        // put its events in this one's recorder or progress.
        let bus = EventBus<AppEvent>()
        let recorder = RecordingEventSubscriber()
        await recorder.subscribe(to: bus)
        let buildProgress = progress?.tagged(["source": source, "slug": label])
        await buildProgress?.subscribe(to: bus)
        defer {
            Task {
                await recorder.unsubscribe(from: bus)
                await buildProgress?.unsubscribe(from: bus)
            }
        }
        outcome.phase("building")

        // Attach this build's log, every level, from LogStore: this process's
        // own log, without a trip through os_log (which the test host may not
        // be writing to — see MultiplexLogHandler). Its entries are the ones
        // tagged with its build; what was logged meanwhile untagged goes in
        // an attachment of its own, since with builds side by side it can't
        // be told whose it was.
        let buildLog = BuildLogContext()
        let logStart = LogStore.shared.nextSequence
        defer {
            LogStore.shared.flush()
            let entries = LogStore.shared.snapshot().entries.filter { $0.seq >= logStart }
            for (name, part) in [
                ("secondchance-\(source)-\(label).txt", entries.filter { $0.build == buildLog.id }),
                ("untagged-\(source)-\(label).txt", entries.filter { $0.build == nil }),
            ] where !part.isEmpty {
                let text = part.map { LogFormatter.full(entry: $0) }.joined(separator: "\n") + "\n"
                Attachment.record(Data(text.utf8), named: name)
            }
        }

        // Drive the real entry point, with a fixed-path input injected so
        // WrappBuildInput takes its env-var branch and no panel appears.
        // Start the build as its own task so waitForCompletion() can run
        // alongside it.
        let viewModel = await MainActor.run {
            WrappBuildViewModel(makeInput: { build.makeInput(outputDir, $0) }, bus: bus)
        }
        // The build's screens, as a person building the game would see them
        // (none with SECOND_CHANCE_HIDE_TEST_UI). Closed when the build is
        // done, unless it failed: that one stays on the screen saying why.
        let window = await BuildWindow.show(viewModel, title: "\(game.title) (\(source))")
        defer {
            Task { @MainActor in
                if case .error = viewModel.currentState { return }
                window?.close()
            }
        }
        // The build takes the log context it starts in, so its entries carry
        // this test's id.
        LogContext.$build.withValue(buildLog) {
            Task { await MainActor.run { Task { await build.start(viewModel) } } }
        }

        // How much disk the build takes at most, for `sc` to know how many
        // can be built at once: its working wrapp, and what's been saved.
        let sampler = Task.detached { [recorder] in
            while !Task.isCancelled {
                let bytes = Self.diskUse(of: [recorder.currentWorkingWrapp, outputDir])
                outcome.notePeak(bytes: bytes)
                if let ticket { await IntegrationStages.build.noteUse(ticket, bytes: bytes) }
                try? await Task.sleep(for: .seconds(15))
            }
        }
        defer { sampler.cancel() }

        // Only a backstop for a build that hangs: the build times out its own
        // installer, patches, and Steam's sign-in and download, and reports
        // which one, so this must not cut a slow but healthy build short.
        let succeeded = await recorder.waitForCompletion(timeout: 3000)
        if !succeeded && recorder.failedError == nil {
            await Self.stopTimedOutBuild(recorder: recorder)
        }
        let finalUse = await Blocking.run { Self.diskUse(of: [outputDir]) }
        outcome.notePeak(bytes: finalUse)
        Attachment.record(Data(recorder.events.map { "\($0)" }.joined(separator: "\n").utf8), named: "\(source)-events-\(label).txt")

        guard afterBuild(recorder, outcome) else { return nil }
        outcome.expect(succeeded, "The build did not complete within the timeout")
        try #require(recorder.failedError == nil, "The build failed: \(String(describing: recorder.failedError))")

        outcome.expect(recorder.detectedGame?.id == game.id,
                       "Detected game \(recorder.detectedGame?.id ?? "nil") but expected \(game.id)")
        outcome.expect(recorder.routedEngine == build.expectedEngine,
                       "Routed engine \(String(describing: recorder.routedEngine)) but expected \(build.expectedEngine)")
        // A failed patch doesn't fail the build, so it has to fail the test.
        for patch in recorder.failedPatches {
            outcome.expect(false, "Patch \(patch.id) failed: \(patch.message)")
        }
        outcome.expect(recorder.signedWrapp != nil, "signed event not emitted")
        let wrapp = try #require(recorder.completedWrapp, "completed event not emitted")
        outcome.expect(try WrappInfo.gameSlug(at: wrapp) == game.id, "Wrapp plist GameSlug isn't \(game.id)")

        LogStore.shared.flush()
        outcome.buildLog = LogStore.shared.snapshot().entries
            .filter { $0.seq >= logStart && $0.build == buildLog.id }
            .map(\.message)
        try await check(recorder, wrapp, outcome)
        return wrapp
    }

    /// A build that times out is still running in this process — typically an
    /// installer that fell back to interactive mode and is waiting for a
    /// person. Left alone it carries on into the next game's test, with its
    /// windows over that game's and its Wine session competing for the
    /// machine. Kill its Wine session so the installer returns, then give the
    /// build a moment to fail and tear down (unmount, remove the temp wrapp).
    private static func stopTimedOutBuild(recorder: RecordingEventSubscriber) async {
        guard let installerPath = recorder.resolvedInstaller?.exePath,
              let tempWrapp = WrappInfo.enclosingAppBundle(of: URL(fileURLWithPath: installerPath)) else {
            return
        }
        await Wine(wrapp: tempWrapp).server.stop()
        _ = await recorder.waitForCompletion(timeout: 60)
    }

    /// What the folders hold on disk together, missing ones counting nothing.
    private nonisolated static func diskUse(of folders: [URL?]) -> Int64 {
        folders.compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .reduce(0) { $0 + DirectorySize.measure($1, within: $1).bytes }
    }

    /// Removes the test's output directory. A wrapp built from discs can hold
    /// read-only directories (a build before they were made writable, or one
    /// stopped partway), which `removeItem` can't delete; give the owner write
    /// permission and try once more, since each one left behind is gigabytes.
    private static func removeOutputDir(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["-R", "u+w", url.path]
            do {
                try chmod.run()
                chmod.waitUntilExit()
                try FileManager.default.removeItem(at: url)
            } catch {
                Issue.record("Could not remove the test's output directory \(url.path): \(error.localizedDescription)")
            }
        }
    }
}

/// One game's result as `sc test integration` shows it, written to the
/// progress stream when the test ends. Expectations go through `expect` so a
/// failed one is counted here as well as recorded as an issue.
final class GameOutcome: @unchecked Sendable {
    let slug: String
    /// Which suite: `disk`, `her-download`, `steam`, `big-fish` or `big-fish-trial`, so `sc` keeps one row
    /// per game per source.
    let source: String
    let progress: ProgressFileWriter?
    let started = Date()
    /// Set once the test has run to its end without throwing.
    var completed = false
    var puppeteerExit: Int32?
    /// Held back because the Mac was too busy to test the game fairly.
    var overloaded = false
    /// Held back because nothing could come to the front (`ScreenState`):
    /// the screen was locked or the display asleep.
    var locked = false
    /// Not tested, for a reason that isn't a failure (e.g. the Steam account
    /// doesn't own the game).
    var skipped: String?
    private var failedExpectations = 0
    /// What to look into that didn't fail the game (`warn`).
    private var warnings: [String] = []
    /// The messages of the build's own log entries, as the build finished,
    /// for a suite's checks to look for what it should have logged.
    var buildLog: [String] = []

    /// What the time went on, so a game that waited for others isn't
    /// charged for it: building, launching, and waiting its turn for either.
    enum Timing: String {
        case build, launch, queued
    }
    private let lock = NSLock()
    private var timings: [Timing: TimeInterval] = [:]
    private var peakBytes: Int64 = 0

    init(slug: String, source: String = "disk", progress: ProgressFileWriter?) {
        self.slug = slug
        self.source = source
        self.progress = progress
        progress?.write(["event": "game", "source": source, "slug": slug, "phase": "started"])
    }

    func expect(_ condition: Bool, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(condition, comment, sourceLocation: sourceLocation)
        if !condition { failedExpectations += 1 }
    }

    /// Something to look into that doesn't fail the game: attached to the
    /// test, and listed under `sc`'s table. (Not an issue, which would fail
    /// it: this Swift Testing has no warning issues.)
    func warn(_ text: String) {
        Attachment.record(Data("\(text)\n".utf8), named: "warning-\(source)-\(slug).txt")
        lock.withLock { warnings.append(text) }
    }

    /// Run `body`, adding the time it takes to `timing`.
    func timed<T>(_ timing: Timing, _ body: () async throws -> T) async rethrows -> T {
        let start = Date()
        defer { add(timing, Date().timeIntervalSince(start)) }
        return try await body()
    }

    func add(_ timing: Timing, _ seconds: TimeInterval) {
        lock.withLock { timings[timing, default: 0] += seconds }
    }

    /// The build's disk use now, kept if it's the most so far.
    func notePeak(bytes: Int64) {
        lock.withLock { peakBytes = max(peakBytes, bytes) }
    }

    func phase(_ phase: String) {
        progress?.write(["event": "game", "source": source, "slug": slug, "phase": phase])
    }

    func finish() {
        let result: String
        if overloaded {
            result = "overloaded"
        } else if locked {
            result = "locked"
        } else if skipped != nil && failedExpectations == 0 {
            // Never over a failed expectation: a build that failed its
            // checks is a failure even if its launch was then skipped.
            result = "skipped"
        } else {
            result = completed && failedExpectations == 0 ? "passed" : "failed"
        }
        var record: [String: Any] = [
            "event": "game", "source": source, "slug": slug, "phase": "finished", "result": result,
            "seconds": Date().timeIntervalSince(started),
        ]
        if let puppeteerExit { record["puppeteerExit"] = Int(puppeteerExit) }
        lock.withLock {
            for (timing, seconds) in timings { record["\(timing.rawValue)Seconds"] = seconds }
            if peakBytes > 0 { record["peakBytes"] = peakBytes }
            if !warnings.isEmpty { record["warnings"] = warnings }
        }
        if let skipped { record["message"] = skipped }
        progress?.write(record)
    }
}
