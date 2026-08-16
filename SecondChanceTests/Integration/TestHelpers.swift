//
//  TestHelpers.swift
//  SecondChanceTests
//
//  Helpers for the per-game integration tests. Resolves installer ISO paths,
//  detects whether installers are present (for test disabling), and reads
//  wrapper Info.plist values for post-install assertions.

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
            "--predicate", "processIdentifier == \(pid) AND subsystem BEGINSWITH 'au.gare.callum.second-chance'",
            "--style", "syslog",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return pipe.fileHandleForReading.readDataToEndOfFile()
        } catch {
            return Data()
        }
    }
}

/// Enumerate the repo root regardless of test working directory.
enum TestPaths {
    /// The repository root directory (parent of `SecondChanceTests/`).
    static let repoRoot: URL = {
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
    static func check() -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: TestPaths.installersDir.path) else {
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
    static let selectedGames: [GameInfo] = {
        let allGames = GameInfoProvider.shared.allGames()

        // Method 1: env var (parallel-safe, preferred)
        if let envFilter = ProcessInfo.processInfo.environment["TEST_GAMES"],
           !envFilter.isEmpty {
            let slugs = Set(envFilter.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespaces)
            })
            return allGames.filter { slugs.contains($0.id) }
        }

        // Method 2: file (not parallel-safe, fallback)
        let filterPath = "/tmp/sc-test-games.txt"
        if let content = try? String(contentsOfFile: filterPath, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let slugs = Set(
                content.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                    .map { String($0) }
                    .filter { !$0.isEmpty }
            )
            return allGames.filter { slugs.contains($0.id) }
        }

        return allGames
    }()
}

/// Reads values from a built wrapper's `Info.plist` for post-install assertions.
enum WrapperInfo {

    /// Locate the built GamePuppeteer.app bundle. Returns `nil` if not found.
    static func gamePuppeteerBundle() -> URL? {
        let url = TestPaths.repoRoot
            .appendingPathComponent("DerivedData/Build/Products/Debug/GamePuppeteer.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Builds a game wrapper for use in integration tests. Returns the `.app` URL.
/// The wrapper is placed in a temp directory; the caller is responsible for cleanup.
enum WrapperBuilder {
    /// Build a wrapper for the given game by running the real install flow.
    /// - Parameters:
    ///   - game: The game to install.
    ///   - keepWrapper: If `true`, persist the wrapper to `built-apps/` instead
    ///     of a temp directory (mirrors `--use-existing` in `test-games.sh`).
    /// - Returns: The built wrapper `.app` URL.
    static func build(for game: GameInfo, keepWrapper: Bool = false) async throws -> URL {
        let disk1 = try InstallerPaths.diskISO(for: game, diskNumber: 1)
            ?? { throw TestError.installerNotFound(game.id) }()
        let disk2 = InstallerPaths.diskISO(for: game, diskNumber: 2)

        let outputDir: URL
        if keepWrapper {
            outputDir = TestPaths.repoRoot.appendingPathComponent("built-apps")
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } else {
            outputDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sc-integration-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        }

        let context = IntegrationTestContext(disk1: disk1, disk2: disk2, outputDir: outputDir)
        let service = InstallationService()
        return try await service.performInstallation(context: context)
    }
}

/// Invokes GamePuppeteer as a subprocess to launch a wrapper and verify the
/// game quits cleanly. Returns the exit code from GamePuppeteer.
enum GamePuppetRunner {
    private static let screenRecordingRelaunchExitCode: Int32 = 5

    @discardableResult
    static func run(
        wrapperURL: URL,
        game: GameInfo,
        timeout: TimeInterval = 90
    ) async throws -> Int32 {
        guard let bundle = WrapperInfo.gamePuppeteerBundle() else {
            throw TestError.gamePuppeteerNotFound
        }
        let slug = game.id

        var firstAttempt = try await Self.launchAndCollect(
            appBundle: bundle,
            wrapperURL: wrapperURL,
            timeout: timeout,
            gameSlug: slug,
            attemptLabel: "initial"
        )

        if firstAttempt.exitCode == screenRecordingRelaunchExitCode {
            Attachment.record(
                Data("GamePuppeteer requested relaunch after manual Screen Recording confirmation.\n".utf8),
                named: "gamepuppeteer-relaunch-\(slug).txt"
            )

            firstAttempt = try await Self.launchAndCollect(
                appBundle: bundle,
                wrapperURL: wrapperURL,
                timeout: timeout,
                gameSlug: slug,
                attemptLabel: "relaunch"
            )
        }

        return firstAttempt.exitCode
    }

    private static func launchAndCollect(
        appBundle: URL,
        wrapperURL: URL,
        timeout: TimeInterval,
        gameSlug: String,
        attemptLabel: String
    ) async throws -> (exitCode: Int32, pid: Int32) {
        let launchTime = Date()
        let (observedExitCode, pid) = try await Self.launchViaLaunchServices(
            appBundle: appBundle,
            arguments: [wrapperURL.path, "--timeout", String(Int(timeout))]
        )

        var effectiveExitCode = observedExitCode

        let logData = SystemLogReader.fetch(pid: pid, since: launchTime)
        guard !logData.isEmpty else {
            throw NSError(
                domain: "GamePuppetRunner",
                code: Int(effectiveExitCode),
                userInfo: [
                    NSLocalizedDescriptionKey: "GamePuppeteer produced no logs (exit code: \(effectiveExitCode), attempt: \(attemptLabel))"
                ]
            )
        }

        Attachment.record(logData, named: "gamepuppeteer-\(attemptLabel)-\(gameSlug).txt")

        if let logText = String(data: logData, encoding: .utf8) {
            let requestedPermission = logText.contains("PERMISSION_GATE: permission_requested")
            let allPermissionsGranted = logText.contains("PERMISSION_GATE: all_permissions_granted")
            let runSucceeded = logText.contains("GAME_PUPPETEER: run_succeeded")

            if logText.contains("Timed out waiting") {
                throw NSError(
                    domain: "GamePuppetRunner",
                    code: Int(effectiveExitCode),
                    userInfo: [
                        NSLocalizedDescriptionKey: "GamePuppeteer timed out waiting for permission grant (exit code: \(effectiveExitCode), attempt: \(attemptLabel))"
                    ]
                )
            }

            if requestedPermission && !allPermissionsGranted {
                effectiveExitCode = screenRecordingRelaunchExitCode
                Attachment.record(
                    Data("Permission request detected without all-permissions-granted marker. Treating as relaunch-required.\n".utf8),
                    named: "gamepuppeteer-exit-code-correction-\(attemptLabel)-\(gameSlug).txt"
                )
            } else if !runSucceeded {
                throw NSError(
                    domain: "GamePuppetRunner",
                    code: Int(effectiveExitCode),
                    userInfo: [
                        NSLocalizedDescriptionKey: "GamePuppeteer did not emit success marker (exit code: \(effectiveExitCode), attempt: \(attemptLabel))"
                    ]
                )
            }
        } else {
            throw NSError(
                domain: "GamePuppetRunner",
                code: Int(effectiveExitCode),
                userInfo: [
                    NSLocalizedDescriptionKey: "GamePuppeteer logs were not UTF-8 decodable (exit code: \(effectiveExitCode), attempt: \(attemptLabel))"
                ]
            )
        }

        let exitCodeSummary = "GamePuppeteer exit code (\(attemptLabel)) for \(gameSlug): observed=\(observedExitCode), effective=\(effectiveExitCode)\n"
        Attachment.record(
            Data(exitCodeSummary.utf8),
            named: "gamepuppeteer-exit-code-\(attemptLabel)-\(gameSlug).txt"
        )

        return (exitCode: effectiveExitCode, pid: pid)
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

    /// Launch GamePuppeteer through LaunchServices so TCC attributes Accessibility
    /// and Screen Recording prompts to GamePuppeteer (its own bundle ID), not to
    /// the Second Chance test host.
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
                userInfo: [NSLocalizedDescriptionKey: "GamePuppeteer bundle identifier is missing"]
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
                NSLocalizedDescriptionKey: "GamePuppeteer launched with invalid PID: \(launchedApp.processIdentifier)"
            ]
        )
    }
}

enum TestError: Error, LocalizedError {
    case installerNotFound(String)
    case gamePuppeteerNotFound

    var errorDescription: String? {
        switch self {
        case .installerNotFound(let slug):
            return "No installer ISO found for game '\(slug)' in installers/"
        case .gamePuppeteerNotFound:
            return "GamePuppeteer binary not found — build the GamePuppeteer target first"
        }
    }
}

// MARK: - Backward-compat: WrapperInfo read methods moved here

extension WrapperInfo {
    /// Read the raw Info.plist dictionary from a wrapper `.app`.
    static func readPlist(at wrapperPath: URL) throws -> [String: Any] {
        let plistPath = wrapperPath.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plistPath.path) else {
            throw NSError(domain: "WrapperInfo", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Info.plist not found at \(plistPath.path)"
            ])
        }
        let data = try Data(contentsOf: plistPath)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw NSError(domain: "WrapperInfo", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Info.plist is not a valid dictionary"
            ])
        }
        return plist
    }

    /// The `GameExePath` value from the wrapper's Info.plist (the exe path the
    /// wrapper was configured to launch).
    static func gameExePath(at wrapperPath: URL) throws -> String? {
        let plist = try readPlist(at: wrapperPath)
        return plist["GameExePath"] as? String
    }

    /// The `GameSlug` value from the wrapper's AppSettings.plist.
    static func gameSlug(at wrapperPath: URL) throws -> String? {
        let settingsPath = wrapperPath.appendingPathComponent("Contents/Resources/AppSettings.plist")
        guard FileManager.default.fileExists(atPath: settingsPath.path),
              let data = try? Data(contentsOf: settingsPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["GameSlug"] as? String
    }
}
