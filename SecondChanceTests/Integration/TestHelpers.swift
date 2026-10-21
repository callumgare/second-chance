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
@testable import SecondChance

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
    /// `start`. Unlike `fetch(pid:since:)` this is not pid-scoped: the wrapp is
    /// launched by WrappPuppeteer, so its pid is not known here.
    static func fetchGame(since start: Date) -> Data {
        fetch(
            predicate: "subsystem == 'au.gare.callum.second-chance.WrappTemplate'",
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
}

/// One integration game at a time, across suites. Each suite is `.serialized`,
/// but Swift Testing runs separate suites side by side, so `--source disk,steam`
/// built and launched two games at once: two wrapps on screen confuse
/// WrappPuppeteer, and the two builds starve each other's Wine.
actor IntegrationSerial {
    static let shared = IntegrationSerial()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func run<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        do {
            let result = try await body()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// Invokes WrappPuppeteer as a subprocess to launch a wrapp and verify the
/// game quits cleanly. Returns the exit code from WrappPuppeteer.
enum AppPuppetRunner {
    @discardableResult
    static func run(
        wrappURL: URL,
        game: GameInfo,
        timeout: TimeInterval = 90
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
        let engine = WrappInfo.gameEngine(at: wrappURL) ?? ""
        let requiredHelpers: [InProcessHelperReport.Helper]
        if engine == "wine" || engine.hasPrefix("wine-") {
            let graphicsAPI = WrappInfo.gameExe(at: wrappURL).map { GameGraphicsAPI(exeAt: $0) } ?? .unknown
            requiredHelpers = [.nativeFullscreen]
                + (graphicsAPI.mayUseCncDdraw ? [.cursorLock] : [])
                + (graphicsAPI.mayUseDirect3D ? [.modeScaling] : [])
                + [.puppetControl]
        } else {
            requiredHelpers = [.puppetControl]
        }

        let attempt = try await Self.launchAndCollect(
            appBundle: bundle,
            wrappURL: wrappURL,
            timeout: timeout,
            gameSlug: slug,
            attemptLabel: "initial",
            requiredHelpers: requiredHelpers
        )

        return attempt.exitCode
    }

    private static func launchAndCollect(
        appBundle: URL,
        wrappURL: URL,
        timeout: TimeInterval,
        gameSlug: String,
        attemptLabel: String,
        requiredHelpers: [InProcessHelperReport.Helper]
    ) async throws -> (exitCode: Int32, pid: Int32) {
        let launchTime = Date()
        let (observedExitCode, pid) = try await Self.launchViaLaunchServices(
            appBundle: appBundle,
            // So a stopped or crashed test run takes the puppeteer, and the
            // wrapp it's driving, down with it.
            arguments: [wrappURL.path, "--timeout", String(Int(timeout)), "--parent-pid", String(getpid())]
        )

        let logData = SystemLogReader.fetch(pid: pid, since: launchTime)
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
        TestConsole.echo(logData, title: "WrappPuppeteer log (\(attemptLabel)) — \(gameSlug)")

        // The game runs in its own process inside the wrapp, so it is not covered
        // by the pid-scoped fetch above and needs its own subsystem query.
        let gameLogData = SystemLogReader.fetchGame(since: launchTime)
        if !gameLogData.isEmpty {
            Attachment.record(gameLogData, named: "game-\(attemptLabel)-\(gameSlug).txt")
            TestConsole.echo(gameLogData, title: "Game log (\(attemptLabel)) — \(gameSlug)")
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
        let gameLog = String(decoding: gameLogData, as: UTF8.self)
        let unarmed = requiredHelpers.filter { !gameLog.contains($0.armedMarker) }
        if !unarmed.isEmpty {
            throw NSError(
                domain: "AppPuppetRunner",
                code: Int(observedExitCode),
                userInfo: [NSLocalizedDescriptionKey: "\(unarmed.map(\.name).joined(separator: " and ")) never armed in the game (no \"\(unarmed[0].armedMarker)\" in the wrapp's log, attempt: \(attemptLabel))"]
            )
        }

        let exitCodeSummary = "WrappPuppeteer exit code (\(attemptLabel)) for \(gameSlug): \(observedExitCode)\n"
        Attachment.record(
            Data(exitCodeSummary.utf8),
            named: "wrapp-puppeteer-exit-code-\(attemptLabel)-\(gameSlug).txt"
        )

        return (exitCode: observedExitCode, pid: pid)
    }

    private static func decodeExitCode(fromKqueueStatus status: Int32) -> Int32 {
        // NOTE_EXIT status representation can vary; accept either direct exit code
        // or waitpid-style encoded status.
        if status >= 0 && status <= 255 {
            return status
        }

        if (status & 0x7f) == 0 {
            return (status >> 8) & 0xff
        }

        return 1
    }

    private static func waitForProcessExitCode(pid: Int32) -> Int32 {
        let kqueueDescriptor = Darwin.kqueue()
        guard kqueueDescriptor >= 0 else {
            return 1
        }
        defer { Darwin.close(kqueueDescriptor) }

        var exitEventRegistration = kevent()
        exitEventRegistration.ident = UInt(pid)
        exitEventRegistration.filter = Int16(EVFILT_PROC)
        exitEventRegistration.flags = UInt16(EV_ADD) | UInt16(EV_ONESHOT)
        exitEventRegistration.fflags = UInt32(NOTE_EXIT)

        let registerResult = withUnsafePointer(to: exitEventRegistration) {
            keventCall(kqueueDescriptor, $0, 1, nil, 0, nil)
        }
        // Registration-only kevent calls (no eventlist) return 0 on success.
        guard registerResult >= 0 else {
            return 1
        }

        var exitEvent = kevent()
        while true {
            let waitResult = withUnsafeMutablePointer(to: &exitEvent) {
                keventCall(kqueueDescriptor, nil, 0, $0, 1, nil)
            }

            if waitResult == 1 {
                return decodeExitCode(fromKqueueStatus: Int32(exitEvent.data))
            }

            if waitResult == -1 && Darwin.errno == EINTR {
                continue
            }

            return 1
        }
    }

    /// Launch WrappPuppeteer through LaunchServices, as an app of its own. It
    /// needs no permissions (the wrapp and the game capture and click their
    /// own windows), so this is only how it has always run: its own process,
    /// found by pid for its log, and stopped with the test by `--parent-pid`.
    private static func launchViaLaunchServices(appBundle: URL, arguments: [String]) async throws -> (exitCode: Int32, pid: Int32) {
        let launchRequestTime = Date()
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = arguments
        config.activates = false
        config.createsNewApplicationInstance = true

        let app = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NSRunningApplication, Error>) in
            NSWorkspace.shared.openApplication(at: appBundle, configuration: config) { runningApp, error in
                if let error { cont.resume(throwing: error) }
                else if let app = runningApp { cont.resume(returning: app) }
                else { cont.resume(throwing: NSError(domain: NSCocoaErrorDomain, code: 0)) }
            }
        }

        let pid = try await resolveValidProcessIdentifier(
            for: app,
            appBundle: appBundle,
            launchRequestTime: launchRequestTime
        )

        // waitpid only works on child processes; NSWorkspace parents to launchd so we
        // use kqueue NOTE_EXIT instead, which works on any process we can observe.
        let exitCode = await Task.detached(priority: .userInitiated) {
            waitForProcessExitCode(pid: pid)
        }.value
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
        let plistPath = wrappPath.appendingPathComponent("Contents/Info.plist")
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

    /// The `GameSlug` value from the wrapp's AppSettings.plist.
    static func gameSlug(at wrappPath: URL) throws -> String? {
        appSetting("GameSlug", at: wrappPath)
    }

    /// The game's .exe inside the wrapp's own prefix, from the `GameExePath`
    /// in its AppSettings.plist; nil for a wrapp without one (ScummVM).
    static func gameExe(at wrappPath: URL) -> URL? {
        guard let path = appSetting("GameExePath", at: wrappPath) else { return nil }
        return wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
            .appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }

    /// The `GameEngine` value from the wrapp's AppSettings.plist
    /// (`wine`, `wine-steam`, `scummvm`, …).
    static func gameEngine(at wrappPath: URL) -> String? {
        appSetting("GameEngine", at: wrappPath)
    }

    private static func appSetting(_ key: String, at wrappPath: URL) -> String? {
        let settingsPath = wrappPath.appendingPathComponent("Contents/Resources/AppSettings.plist")
        guard FileManager.default.fileExists(atPath: settingsPath.path),
              let data = try? Data(contentsOf: settingsPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist[key] as? String
    }
}
