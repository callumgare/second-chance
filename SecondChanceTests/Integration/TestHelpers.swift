//
//  TestHelpers.swift
//  SecondChanceTests
//
//  Helpers for the per-game integration tests. Resolves installer ISO paths,
//  detects whether installers are present (for test disabling), and reads
//  wrapp Info.plist values for post-install assertions.

import Foundation
import Darwin
import AppKit
import Testing
@testable import ProcessKit
@testable import SecondChance
@testable import SecondChanceKit
@testable import WindowsFormats
@testable import WineKit
@testable import WrappFormat
@testable import WrappLogging
import GameCatalog

// Rename the kevent C syscall so it doesn't collide with Swift's kevent struct init.
@_silgen_name("kevent")
private func keventCall(
    _ kq: Int32,
    _ changelist: UnsafePointer<kevent>?,
    _ nchanges: Int32,
    _ eventlist: UnsafeMutablePointer<kevent>?,
    _ nevents: Int32,
    _ timeout: UnsafePointer<timespec>?
) -> Int32

/// Reads log entries from Apple's unified logging system via `log show`.
enum SystemLogReader {

    /// Fetch all log lines for `pid` since `start` (padded back 5 s to avoid clipping).
    static func fetch(pid: Int32, since start: Date) -> Data {
        fetch(
            predicate: "processIdentifier == \(pid) AND subsystem BEGINSWITH 'au.gare.callum.second-chance'",
            since: start
        )
    }

    /// Fetch log lines emitted by the wrapp itself (the game container) since
    /// `start`: its own, and the shared package's that it logged (the Steam
    /// sign-in, Wine's desktop), whose subsystem is `…Shared`. Unlike
    /// `fetch(pid:since:)` this is not pid-scoped: the wrapp is launched by
    /// WrappPuppeteer, so its pid is not known here; its executable is
    /// always WrappTemplate.
    static func fetchGame(since start: Date) -> Data {
        fetch(
            predicate: "subsystem == 'au.gare.callum.second-chance.WrappTemplate'"
                + " OR (subsystem == 'au.gare.callum.second-chance.Shared' AND process == 'WrappTemplate')",
            since: start
        )
    }

    /// Run `log show` with `predicate` and return its entries as lines in
    /// Second Chance's own compact format, with the process that logged each
    /// one in front of the category (`WrappPuppeteer/main`), so they read
    /// like the rest of the test output instead of in a third format.
    static func fetch(predicate: String, since start: Date) -> Data {
        Data(compactLines(fromNDJSON: fetchRaw(predicate: predicate, since: start)).utf8)
    }

    /// `log show --style ndjson` output as compact lines.
    static func compactLines(fromNDJSON data: Data) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm:ss.SSS"
        var lines: [String] = []
        for raw in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let message = object["eventMessage"] as? String else { continue }
            let stamp = (object["timestamp"] as? String).flatMap(parser.date(from:)).map(time.string(from:)) ?? "??:??:??.???"
            // OSLogHandler maps warning and error both to OSLog's error type.
            let level: String
            switch object["messageType"] as? String {
            case "Debug": level = "debug"
            case "Error": level = "error"
            case "Fault": level = "critical"
            default: level = "notice"
            }
            let process = ((object["processImagePath"] as? String) ?? "?").split(separator: "/").last.map(String.init) ?? "?"
            let category = (object["category"] as? String) ?? ""
            lines.append("\(stamp)  \(level)  \(process)/\(category)  \(message)")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Run `log show` with `predicate` and return its stdout, as ndjson.
    private static func fetchRaw(predicate: String, since start: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let paddedStart = start.addingTimeInterval(-5)
        let startStr = formatter.string(from: paddedStart)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--start", startStr,
            "--predicate", predicate,
            "--style", "ndjson",
            // Debug entries too: the attachments keep the detail, the
            // console echo leaves it out.
            "--info", "--debug",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        // `log show` writes progress and warnings to stderr and nothing here
        // reads them. A Pipe would fill and block the child forever, so discard.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            // Drain BEFORE waiting, never after. A pipe buffers roughly 64 KB;
            // once `log show` fills it the child blocks waiting for a reader
            // while waitUntilExit() blocks waiting for the child to exit, and
            // the test run hangs forever with no output. A long game session
            // easily clears 64 KB, which is why this only bit sometimes.
            // readDataToEndOfFile() returns at EOF, which the child's exit gives.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        } catch {
            return Data()
        }
    }
}

/// Echoes captured subprocess logs into the test output. Second Chance's own
/// logs show up because the tests run inside it; WrappPuppeteer and the game are
/// separate processes, so their logs only reach the console via this.
enum TestConsole {
    static func echo(_ data: Data, title: String) {
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Debug detail stays in the attachment; the console gets notice and up.
        let shown = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("  debug  ") }
            .joined(separator: "\n")
        let rule = String(repeating: "─", count: 10)
        print("\(rule) \(title) \(rule)")
        print(shown, terminator: shown.hasSuffix("\n") ? "" : "\n")
        print("\(rule) end \(title) \(rule)")
        fflush(stdout)
    }
}

/// Enumerate the repo root regardless of test working directory.
enum TestPaths {
    /// The repository root directory (parent of `SecondChanceTests/`).
    ///
    /// `REPO_ROOT` (set by `sc test` as `TEST_RUNNER_REPO_ROOT`) wins over
    /// `#filePath`, which is baked in at compile time and so points at the
    /// wrong place when a build is copied to another machine.
    static let repoRoot: URL = {
        if let override = ProcessInfo.processInfo.environment["REPO_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // Tests run with the host app's bundle; derive repo root from #filePath.
        let thisFile = URL(fileURLWithPath: #filePath)
        // thisFile = .../SecondChanceTests/Integration/TestHelpers.swift
        return thisFile
            .deletingLastPathComponent()  // Integration/
            .deletingLastPathComponent()  // SecondChanceTests/
            .deletingLastPathComponent()  // repo root
    }()

    /// The `installers/` directory at the repo root.
    static let installersDir: URL = repoRoot.appendingPathComponent("installers")

    /// Where prebuilt wrapps live: `WRAPPS_DIR` (set by `sc test` as
    /// `TEST_RUNNER_WRAPPS_DIR` from its `--wrapps-dir`), else `built-apps/`.
    static let wrappsDir: URL = {
        if let override = ProcessInfo.processInfo.environment["WRAPPS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return repoRoot.appendingPathComponent("built-apps")
    }()
}

/// Resolves installer ISO paths for a given game.
enum InstallerPaths {
    /// The path to `installers/<slug>/disk-N.iso`, or `nil` if it doesn't exist.
    static func diskISO(for game: GameInfo, diskNumber: Int) -> URL? {
        let isoURL = TestPaths.installersDir
            .appendingPathComponent(game.id)
            .appendingPathComponent("disk-\(diskNumber).iso")

        return FileManager.default.fileExists(atPath: isoURL.path) ? isoURL : nil
    }

    /// The game's Her Interactive downloads: `installers/<slug>/her-download*`
    /// with a `.exe` (Windows installer) or `.dmg` (Mac download) extension,
    /// the Windows one first.
    static func herDownloads(for game: GameInfo) -> [URL] {
        let dir = TestPaths.installersDir.appendingPathComponent(game.id)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return ["exe", "dmg"].flatMap { ext in
            files.filter { $0.lastPathComponent.lowercased().hasPrefix("her-download") && $0.pathExtension.lowercased() == ext }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    /// The path to a directory containing the disk contents (as an alternative
    /// to an ISO). Returns `nil` if no such directory exists.
    static func diskDirectory(for game: GameInfo) -> URL? {
        let dirURL = TestPaths.installersDir.appendingPathComponent(game.id)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }

        // Only return it if it contains files (not just disk-N.iso at top level)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: dirURL.path)
        return (contents?.isEmpty == false) ? dirURL : nil
    }
}

/// Whether any installer ISOs are present in `installers/`. Used by the
/// `.disabled(if:)` trait so integration tests no-op cleanly on CI / machines
/// without the (gitignored) real installers.
enum InstallersPresent {
    /// Set by `sc test integration` (as `TEST_RUNNER_REQUIRE_INSTALLERS`) when the
    /// integration suite was asked for by name. Then a missing ISO must fail
    /// the run — the per-game `#require` reports the path it looked at —
    /// rather than disable the suite and let it pass having tested nothing.
    static let required = ProcessInfo.processInfo.environment["REQUIRE_INSTALLERS"] == "1"

    /// Whether the integration suite should run: always when required,
    /// otherwise only if some `installers/<slug>/disk-1.iso` exists.
    static func shouldRun() -> Bool {
        required || check()
    }

    static func check() -> Bool {
        let fm = FileManager.default
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: TestPaths.installersDir.path)
        } catch {
            TestConsole.echo(
                Data("Cannot read \(TestPaths.installersDir.path): \(error.localizedDescription)\n".utf8),
                title: "Installers directory"
            )
            return false
        }
        for entry in entries {
            let dir = TestPaths.installersDir.appendingPathComponent(entry)
            let iso = dir.appendingPathComponent("disk-1.iso")
            if fm.fileExists(atPath: iso.path) { return true }
        }
        return false
    }
}

/// Filters which games integration tests run. Supports two methods:
///
/// 1. `TEST_RUNNER_TEST_GAMES` environment variable (preferred — parallel-safe):
///    Use the `TEST_RUNNER_` prefix so xcodebuild forwards it to the test process
///    (with the prefix stripped) as `TEST_GAMES`:
///      TEST_RUNNER_TEST_GAMES=secrets-can-kill xcodebuild test ...
///      TEST_RUNNER_TEST_GAMES=secrets-can-kill,blackmoor-manor xcodebuild test ...
///
/// 2. Filter file at `/tmp/sc-test-games.txt` (fallback — not parallel-safe):
///    Write slugs (one per line or comma-separated) to the file.
///      echo secrets-can-kill > /tmp/sc-test-games.txt
///
/// The env var takes priority. When neither is set, all games run.
enum TestGameFilter {
    /// The slugs asked for, or `nil` when no filter is set (run everything).
    static let requestedSlugs: Set<String>? = {
        // Method 1: env var (parallel-safe, preferred)
        if let envFilter = ProcessInfo.processInfo.environment["TEST_GAMES"],
           !envFilter.isEmpty {
            return Set(envFilter.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespaces)
            })
        }

        // Method 2: file (not parallel-safe, fallback)
        let filterPath = "/tmp/sc-test-games.txt"
        if let content = try? String(contentsOfFile: filterPath, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Set(
                content.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                    .map { String($0) }
                    .filter { !$0.isEmpty }
            )
        }

        return nil
    }()

    static let selectedGames: [GameInfo] = {
        let allGames = GameInfoProvider.shared.allGames()
        guard let slugs = requestedSlugs else { return allGames }
        return allGames.filter { slugs.contains($0.id) }
    }()

    /// Requested slugs that match no game. A typo would otherwise filter the
    /// parameterized test down to zero cases, which passes having run nothing.
    static var unknownSlugs: [String] {
        guard let slugs = requestedSlugs else { return [] }
        let known = Set(GameInfoProvider.shared.allGames().map(\.id))
        return slugs.subtracting(known).sorted()
    }
}

/// Reads values from a built wrapp's `Info.plist` for post-install assertions.
enum WrappInfo {

    /// Locate the built WrappPuppeteer.app bundle. Returns `nil` if not found.
    static func wrappPuppeteerBundle() -> URL? {
        let url = TestPaths.repoRoot
            .appendingPathComponent("DerivedData/Build/Products/Debug/WrappPuppeteer.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The outermost `.app` bundle containing `url`, if any.
    static func enclosingAppBundle(of url: URL) -> URL? {
        var bundle = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            bundle.appendPathComponent(component)
            if component.hasSuffix(".app") { return bundle }
        }
        return nil
    }
}

/// Points a disk build at the game a wrapp has installed, as someone might
/// choose an installed game's folder instead of its disc, and expects it
/// turned down with `installedGameNotInstaller` before anything is copied.
/// Run on a built wrapp before it is deleted, for every source: its
/// installed game is what such a folder holds. A ScummVM wrapp holds only
/// the copied disc, which is an installer, so it has nothing to check.
enum InstalledGameCheck {
    static func run(wrapp: URL, game: GameInfo, outcome: GameOutcome) async {
        guard WrappInfo.gameEngine(at: wrapp) != .scummvm,
              let installedGame = WrappInfo.gameExe(at: wrapp)?.deletingLastPathComponent() else {
            return
        }
        outcome.phase("checking installed game")

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-installed-game-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }

        // Its own bus, not EventBus.app: the test host's window follows
        // that, and would show this expected failure as its error screen.
        let bus = EventBus<AppEvent>()
        let recorder = RecordingEventSubscriber()
        await recorder.subscribe(to: bus)
        // A log context of its own, so its lines aren't another game's
        // build's untagged ones.
        let build = LogContext.$build.withValue(BuildLogContext()) {
            Task { @MainActor in
                let builder = DiskWrappBuilder(installerRunner: GameInstallerRunner(bus: bus), bus: bus)
                _ = try await builder.build(input: WrappBuildInput(disk1: installedGame, outputDir: outputDir))
            }
        }
        // It's turned down before the copy, so in moments.
        let completed = await recorder.waitForCompletion(timeout: 120)
        if !completed && recorder.failedError == nil {
            // Not turned down, and an installer is running: left alone it
            // carries on into the next game's test, waiting on a dialog.
            build.cancel()
            if let installer = recorder.resolvedInstaller?.exePath,
               let tempWrapp = WrappInfo.enclosingAppBundle(of: URL(fileURLWithPath: installer)) {
                await Wine(wrapp: tempWrapp).server.stop()
            }
            _ = await recorder.waitForCompletion(timeout: 60)
        }
        await recorder.unsubscribe(from: bus)

        let eventTrace = recorder.events.map { "\($0)" }.joined(separator: "\n")
        Attachment.record(Data(eventTrace.utf8), named: "installed-game-check-events-\(game.id).txt")

        outcome.expect(!completed && recorder.completedWrapp == nil,
                       "A build from \(game.id)'s installed game (\(installedGame.path)) made a wrapp")
        outcome.expect(recorder.failedError == .installedGameNotInstaller,
                       "A build from \(game.id)'s installed game failed with \(String(describing: recorder.failedError)), not installedGameNotInstaller")
    }
}

/// Invokes WrappPuppeteer as a subprocess to launch a wrapp and verify the
/// game quits cleanly. Returns the exit code from WrappPuppeteer.
enum AppPuppetRunner {
    @discardableResult
    /// `onWarning` hears each warning WrappPuppeteer gave
    /// (`WRAPP_PUPPETEER: warning:`): something to look into that doesn't
    /// fail the game, such as a splash screen it no longer recognises.
    ///
    /// `quitFromMenu` quits the game through its Quit menu item (⌘⌥Q) once
    /// at the menu, rather than its Exit button. Not in a VM.
    static func run(
        wrappURL: URL,
        game: GameInfo,
        quitFromMenu: Bool = false,
        onWarning: @escaping (String) -> Void = { _ in }
    ) async throws -> Int32 {
        guard let bundle = WrappInfo.wrappPuppeteerBundle() else {
            throw TestError.wrappPuppeteerNotFound
        }
        let slug = game.id

        // A Wine game has to arm native fullscreen, cursor lock unless it
        // draws with Direct3D (so never through cnc-ddraw), and mode scaling
        // unless it draws through cnc-ddraw; nothing else would notice if they
        // didn't (the game still plays, in a window, or in a corner of the
        // screen). Every game arms puppet control, which WrappPuppeteer drives
        // it through; naming it here says so when it didn't, rather than
        // leaving WrappPuppeteer's failure to explain it.
        let requiredHelpers: [InProcessHelperReport.Helper]
        if WrappInfo.gameEngine(at: wrappURL)?.runsInWine == true {
            // As the wrapp decides: the catalog says for a Big Fish .exe,
            // whose imports Armadillo hides.
            let graphicsAPI = WrappInfo.gameExe(at: wrappURL).map { GameGraphicsAPI(exeAt: $0, game: game) } ?? .unknown
            requiredHelpers = [.nativeFullscreen]
                + (graphicsAPI.mayUseCncDdraw ? [.cursorLock] : [])
                + (graphicsAPI.mayUseDirect3D ? [.modeScaling] : [])
                + [.quitWatch, .puppetControl]
        } else {
            requiredHelpers = [.puppetControl]
        }
        // A game that starts Steam logs how far its sign-in got, so a stalled
        // one can be followed in the log.
        let requiredLines = WrappInfo.gameEngine(at: wrappURL)?.needsSteam == true
            ? [SteamSignInWatch.waitingMarker, SteamSignInWatch.signedInMarker] : []

        // `sc test integration --vm`: launch it in the VM instead.
        if let vm = VMTarget.current {
            return try await VMPuppetRunner.run(in: vm, puppeteer: bundle, wrappURL: wrappURL, gameSlug: slug,
                                                requiredHelpers: requiredHelpers, requiredLines: requiredLines,
                                                onWarning: onWarning)
        }

        let attempt = try await Self.launchAndCollect(
            appBundle: bundle,
            wrappURL: wrappURL,
            gameSlug: slug,
            attemptLabel: quitFromMenu ? "menu-quit" : "initial",
            extraArguments: quitFromMenu ? ["--quit-from-menu"] : [],
            requiredHelpers: requiredHelpers,
            requiredLines: requiredLines,
            onWarning: onWarning
        )

        return attempt.exitCode
    }

    private static func launchAndCollect(
        appBundle: URL,
        wrappURL: URL,
        gameSlug: String,
        attemptLabel: String,
        extraArguments: [String] = [],
        requiredHelpers: [InProcessHelperReport.Helper],
        requiredLines: [String],
        onWarning: (String) -> Void
    ) async throws -> (exitCode: Int32, pid: Int32) {
        let launchTime = Date()
        // WrappPuppeteer isn't this process's child, so its exit status can't
        // be read from here: it writes it to this file instead.
        let exitCodeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("wrapp-puppeteer-exit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: exitCodeFile) }
        let (observedExitCode, pid) = try await Self.launchViaLaunchServices(
            appBundle: appBundle,
            // So a stopped or crashed test run takes the puppeteer, and the
            // wrapp it's driving, down with it.
            arguments: [wrappURL.path, "--max-runtime", String(Int(Self.maxRuntime)), "--exit-code-file", exitCodeFile.path,
                        "--parent-pid", String(getpid())] + extraArguments,
            exitCodeFile: exitCodeFile
        )

        let logData = SystemLogReader.fetch(pid: pid, since: launchTime)
        // The game runs in its own process inside the wrapp, so it is not covered
        // by the pid-scoped fetch above and needs its own subsystem query.
        let gameLogData = SystemLogReader.fetchGame(since: launchTime)
        attachScreenshots(loggedIn: String(decoding: logData, as: UTF8.self), gameSlug: gameSlug, attemptLabel: attemptLabel)
        try judge(puppeteerLog: logData, gameLog: gameLogData, exitCode: observedExitCode, gameSlug: gameSlug,
                  attemptLabel: attemptLabel, requiredHelpers: requiredHelpers, requiredLines: requiredLines, onWarning: onWarning)
        return (exitCode: observedExitCode, pid: pid)
    }

    /// Judge a run from WrappPuppeteer's log and the game's (compact lines,
    /// as `SystemLogReader` gives them), attaching and echoing both. Throws
    /// the reason a run failed; a local run and one in a VM
    /// (`VMPuppetRunner`) are judged alike.
    static func judge(
        puppeteerLog logData: Data,
        gameLog gameLogData: Data,
        exitCode observedExitCode: Int32,
        gameSlug: String,
        attemptLabel: String,
        requiredHelpers: [InProcessHelperReport.Helper],
        requiredLines: [String] = [],
        onWarning: (String) -> Void = { _ in }
    ) throws {
        guard !logData.isEmpty else {
            throw NSError(
                domain: "AppPuppetRunner",
                code: Int(observedExitCode),
                userInfo: [
                    NSLocalizedDescriptionKey: "WrappPuppeteer produced no logs (exit code: \(observedExitCode), attempt: \(attemptLabel))"
                ]
            )
        }

        Attachment.record(logData, named: "wrapp-puppeteer-\(attemptLabel)-\(gameSlug).txt")
        for warning in warnings(in: String(decoding: logData, as: UTF8.self)) { onWarning(warning) }
        TestConsole.echo(logData, title: "WrappPuppeteer log (\(attemptLabel)) — \(gameSlug)")

        if !gameLogData.isEmpty {
            Attachment.record(gameLogData, named: "game-\(attemptLabel)-\(gameSlug).txt")
            TestConsole.echo(gameLogData, title: "Game log (\(attemptLabel)) — \(gameSlug)")
        }

        let gameLog = String(decoding: gameLogData, as: UTF8.self)
        // Steam held the launch on its "playing on another computer"
        // question: the puppeteer only sees a game that never appeared.
        if gameLog.contains(SteamLogs.playingElsewhereMarker) {
            throw NSError(
                domain: "AppPuppetRunner",
                code: Int(observedExitCode),
                userInfo: [NSLocalizedDescriptionKey: "Steam wouldn't start the game: the Steam account was playing a game on another computer, "
                    + "and Steam asked whether to stop it there (attempt: \(attemptLabel)). Stop the other game and run this one again."]
            )
        }

        // The wrapp's own verdict on the game's exit says more than the
        // puppeteer's, which only sees the game gone or the wrapp still open.
        if let verdict = gameLog.components(separatedBy: "\n").first(where: { $0.contains(GameQuitCheck.failureMarker) }),
           let range = verdict.range(of: GameQuitCheck.failureMarker) {
            throw NSError(
                domain: "AppPuppetRunner",
                code: Int(observedExitCode),
                userInfo: [NSLocalizedDescriptionKey: "The game quit unexpectedly\(verdict[range.upperBound...]) (attempt: \(attemptLabel))"]
            )
        }

        if let logText = String(data: logData, encoding: .utf8) {
            let runSucceeded = logText.contains("WRAPP_PUPPETEER: run_succeeded")

            if !runSucceeded {
                let failureMarker = "WRAPP_PUPPETEER: run_failed: "
                let reason = logText.components(separatedBy: "\n")
                    .last(where: { $0.contains(failureMarker) })?
                    .components(separatedBy: failureMarker).last
                let description = reason.map { "WrappPuppeteer failed: \($0) (exit code: \(observedExitCode), attempt: \(attemptLabel))" }
                    ?? "WrappPuppeteer did not emit success marker (exit code: \(observedExitCode), attempt: \(attemptLabel))"
                throw NSError(
                    domain: "AppPuppetRunner",
                    code: Int(observedExitCode),
                    userInfo: [NSLocalizedDescriptionKey: description]
                )
            }
        } else {
            throw NSError(
                domain: "AppPuppetRunner",
                code: Int(observedExitCode),
                userInfo: [
                    NSLocalizedDescriptionKey: "WrappPuppeteer logs were not UTF-8 decodable (exit code: \(observedExitCode), attempt: \(attemptLabel))"
                ]
            )
        }

        // Checked after the puppeteer's own verdict, which says more when the
        // game didn't get as far as its window at all.
        let unarmed = requiredHelpers.filter { !gameLog.contains($0.armedMarker) }
        if !unarmed.isEmpty {
            throw NSError(
                domain: "AppPuppetRunner",
                code: Int(observedExitCode),
                userInfo: [NSLocalizedDescriptionKey: "\(unarmed.map(\.name).joined(separator: " and ")) never armed in the game "
                    + "(no \"\(unarmed[0].armedMarker)\" in the wrapp's log, attempt: \(attemptLabel))"]
            )
        }

        if let missing = requiredLines.first(where: { !gameLog.contains($0) }) {
            throw NSError(
                domain: "AppPuppetRunner",
                code: Int(observedExitCode),
                userInfo: [NSLocalizedDescriptionKey: "The wrapp's log has no \"\(missing)\" line (attempt: \(attemptLabel))"]
            )
        }

        let exitCodeSummary = "WrappPuppeteer exit code (\(attemptLabel)) for \(gameSlug): \(observedExitCode)\n"
        Attachment.record(
            Data(exitCodeSummary.utf8),
            named: "wrapp-puppeteer-exit-code-\(attemptLabel)-\(gameSlug).txt"
        )
    }

    /// What WrappPuppeteer warned about, from its `WRAPP_PUPPETEER: warning:`
    /// lines, in order.
    static func warnings(in log: String) -> [String] {
        let marker = "WRAPP_PUPPETEER: warning: "
        return log.components(separatedBy: "\n").compactMap { line in
            line.range(of: marker).map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces) }
        }
    }

    /// The paths of the screenshots WrappPuppeteer logs, with 📸, when a run
    /// goes wrong: the game window, and the whole screen when it has Screen
    /// Recording.
    static func screenshotPaths(in log: String) -> [String] {
        log.components(separatedBy: "\n").compactMap { line in
            guard let marker = line.range(of: "📸 ") else { return nil }
            let path = line[marker.upperBound...].components(separatedBy: ": ").last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return path.hasPrefix("/") && path.hasSuffix(".png") ? path : nil
        }
    }

    /// Attach the screenshots the run logged, as they're otherwise left in
    /// the test Mac's /tmp. Only for a run on this Mac: a run in a VM leaves
    /// them in the VM.
    private static func attachScreenshots(loggedIn log: String, gameSlug: String, attemptLabel: String) {
        for path in screenshotPaths(in: log) {
            let url = URL(fileURLWithPath: path)
            do {
                let data = try Data(contentsOf: url)
                Attachment.record(data, named: "screenshot-\(attemptLabel)-\(gameSlug)-\(url.lastPathComponent)")
            } catch {
                Attachment.record(Data("Couldn't read \(path): \(error.localizedDescription)\n".utf8),
                                  named: "screenshot-\(attemptLabel)-\(gameSlug)-\(url.lastPathComponent).txt")
            }
        }
    }

    /// The most a WrappPuppeteer run may take (`--max-runtime`), above its
    /// phases' own limits added up; the test gives up on it a little after.
    static let maxRuntime: TimeInterval = 2700

    /// Wait for `pid` to exit, then read the exit code it wrote to
    /// `exitCodeFile`. 1 when it wrote none (it was killed), or when it is
    /// still running well past `maxRuntime`, in which case it is killed.
    private static func waitForProcessExitCode(pid: Int32, exitCodeFile: URL) -> Int32 {
        guard waitForProcessExit(pid: pid, timeout: maxRuntime + 120) else {
            kill(pid, SIGTERM)
            return 1
        }
        guard let text = try? String(contentsOf: exitCodeFile, encoding: .utf8),
              let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 1 }
        return code
    }

    /// Whether `pid` exited within `timeout`; true too if it had already gone.
    private static func waitForProcessExit(pid: Int32, timeout: TimeInterval) -> Bool {
        let kqueueDescriptor = Darwin.kqueue()
        guard kqueueDescriptor >= 0 else { return true }
        defer { Darwin.close(kqueueDescriptor) }

        var exitEventRegistration = kevent()
        exitEventRegistration.ident = UInt(pid)
        exitEventRegistration.filter = Int16(EVFILT_PROC)
        exitEventRegistration.flags = UInt16(EV_ADD) | UInt16(EV_ONESHOT)
        exitEventRegistration.fflags = UInt32(NOTE_EXIT)

        let registerResult = withUnsafePointer(to: exitEventRegistration) {
            keventCall(kqueueDescriptor, $0, 1, nil, 0, nil)
        }
        // ESRCH: it exited before the registration.
        guard registerResult >= 0 else { return true }

        let deadline = Date().addingTimeInterval(timeout)
        var exitEvent = kevent()
        while true {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            var wait = timespec(tv_sec: Int(remaining), tv_nsec: 0)
            let waitResult = withUnsafeMutablePointer(to: &exitEvent) { event in
                withUnsafePointer(to: &wait) { keventCall(kqueueDescriptor, nil, 0, event, 1, $0) }
            }
            if waitResult == 1 { return true }
            if waitResult == -1 && Darwin.errno == EINTR { continue }
            if waitResult == 0 { return false }
            return true
        }
    }

    /// Launch WrappPuppeteer through LaunchServices, as an app of its own. It
    /// needs no permissions (the wrapp and the game capture and click their
    /// own windows), so this is only how it has always run: its own process,
    /// found by pid for its log, and stopped with the test by `--parent-pid`.
    private static func launchViaLaunchServices(appBundle: URL, arguments: [String],
                                                exitCodeFile: URL) async throws -> (exitCode: Int32, pid: Int32) {
        let launchRequestTime = Date()
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = arguments
        config.activates = false
        config.createsNewApplicationInstance = true

        let app = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NSRunningApplication, Error>) in
            NSWorkspace.shared.openApplication(at: appBundle, configuration: config) { runningApp, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let app = runningApp {
                    cont.resume(returning: app)
                } else {
                    cont.resume(throwing: NSError(domain: NSCocoaErrorDomain, code: 0))
                }
            }
        }

        let pid = try await resolveValidProcessIdentifier(
            for: app,
            appBundle: appBundle,
            launchRequestTime: launchRequestTime
        )

        // waitpid only works on child processes; NSWorkspace parents to launchd so we
        // use kqueue NOTE_EXIT instead, which works on any process we can observe,
        // but says nothing of its exit status: that comes from the file.
        let exitCode = await Blocking.run {
            waitForProcessExitCode(pid: pid, exitCodeFile: exitCodeFile)
        }
        return (exitCode: exitCode, pid: pid)
    }

    private static func resolveValidProcessIdentifier(
        for launchedApp: NSRunningApplication,
        appBundle: URL,
        launchRequestTime: Date
    ) async throws -> Int32 {
        if launchedApp.processIdentifier > 0 {
            return launchedApp.processIdentifier
        }

        guard let bundleIdentifier = Bundle(url: appBundle)?.bundleIdentifier else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "WrappPuppeteer bundle identifier is missing"]
            )
        }

        let deadline = Date().addingTimeInterval(5)
        let launchDateThreshold = launchRequestTime.addingTimeInterval(-1)

        while Date() < deadline {
            let runningCandidates = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { $0.processIdentifier > 0 && !$0.isTerminated }
                .sorted {
                    ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast)
                }

            if let matchedCandidate = runningCandidates.first(where: {
                guard let launchDate = $0.launchDate else { return true }
                return launchDate >= launchDateThreshold
            }) ?? runningCandidates.first {
                return matchedCandidate.processIdentifier
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        throw NSError(
            domain: NSCocoaErrorDomain,
            code: 0,
            userInfo: [
                NSLocalizedDescriptionKey: "WrappPuppeteer launched with invalid PID: \(launchedApp.processIdentifier)"
            ]
        )
    }
}

enum TestError: Error, LocalizedError {
    case wrappPuppeteerNotFound

    var errorDescription: String? {
        switch self {
        case .wrappPuppeteerNotFound:
            return "WrappPuppeteer.app not found in DerivedData — it builds as a SecondChanceTests dependency, so this means the build did not complete"
        }
    }
}

// MARK: - WrappInfo plist readers

extension WrappInfo {
    /// Read the raw Info.plist dictionary from a wrapp `.app`.
    static func readPlist(at wrappPath: URL) throws -> [String: Any] {
        let plistPath = WrappLayout(app: wrappPath).infoPlist
        guard FileManager.default.fileExists(atPath: plistPath.path) else {
            throw NSError(domain: "WrappInfo", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Info.plist not found at \(plistPath.path)"
            ])
        }
        let data = try Data(contentsOf: plistPath)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw NSError(domain: "WrappInfo", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Info.plist is not a valid dictionary"
            ])
        }
        return plist
    }

    /// The `GameExePath` value from the wrapp's Info.plist (the exe path the
    /// wrapp was configured to launch).
    static func gameExePath(at wrappPath: URL) throws -> String? {
        let plist = try readPlist(at: wrappPath)
        return plist["GameExePath"] as? String
    }

    /// The wrapp's AppSettings.plist; nil when it has none it can read.
    static func settings(at wrappPath: URL) -> WrappSettings? {
        try? WrappSettings(of: WrappLayout(app: wrappPath))
    }

    /// The game's slug from the wrapp's AppSettings.plist.
    static func gameSlug(at wrappPath: URL) throws -> String? {
        settings(at: wrappPath)?.gameSlug
    }

    /// The program the wrapp's launch starts, in the wrapp: a Wine or DOSBox
    /// program on its C:, or a ScummVM game's data folder; nil for a wrapp
    /// with no settings, or a launch whose program isn't in it (Steam's).
    static func gameExe(at wrappPath: URL) -> URL? {
        guard let launch = settings(at: wrappPath)?.launch else { return nil }
        let layout = WrappLayout(app: wrappPath)
        return layout.location(launch.program.hasPrefix("scummvm:") ? launch.path : launch.program)
    }

    /// The game's engine from the wrapp's AppSettings.plist.
    static func gameEngine(at wrappPath: URL) -> GameInfo.GameEngine? {
        settings(at: wrappPath)?.engine
    }
}
