import ArgumentParser
import Foundation
import GameCatalog
import Testing
@testable import SCKit

@Suite("Swift Testing output parsing")
struct TestEventTests {
    @Test("Lines as xcodebuild prints them", arguments: [
        ("􀟈 Test \"Detect game\" started.", TestEvent.started(.test, name: "Detect game")),
        ("􀟈 Test subscribersReceiveEvents() started.", .started(.test, name: "subscribersReceiveEvents()")),
        ("􀟈 Suite \"LogStore\" started.", .started(.suite, name: "LogStore")),
        ("􁁛 Test \"Patch ids are unique\" passed after 0.016 seconds.", .finished(.test, name: "Patch ids are unique", outcome: .passed, seconds: 0.016)),
        ("􁁛 Test \"Detect game from fingerprint\" with 34 test cases passed after 0.016 seconds.",
         .finished(.test, name: "Detect game from fingerprint", outcome: .passed, seconds: 0.016)),
        ("􀢄 Test \"Quoted \"name\" here\" failed after 0.1 seconds with 1 issue.",
         .finished(.test, name: "Quoted \"name\" here", outcome: .failed, seconds: 0.1)),
        ("􀙟 Test \"Needs fixtures\" skipped: \"No fixture\"", .finished(.test, name: "Needs fixtures", outcome: .skipped, seconds: nil)),
        ("􀢄 Test \"Y\" recorded an issue at A.swift:3:5: Expectation failed: x == 1",
         .issue(name: "Y", detail: "at A.swift:3:5: Expectation failed: x == 1")),
        ("􁁛 Suite \"LogWindow streaming\" passed after 4.938 seconds.", .finished(.suite, name: "LogWindow streaming", outcome: .passed, seconds: 4.938)),
        ("􁁛 Test run with 73 tests in 13 suites passed after 4.938 seconds.", .runFinished(passed: true)),
        ("􀢄 Test run with 73 tests in 13 suites failed after 4.938 seconds with 2 issues.", .runFinished(passed: false)),
        ("XCTestOutputBar􁁛 Suite \"Docs table\" passed after 0.067 seconds.", .finished(.suite, name: "Docs table", outcome: .passed, seconds: 0.067)),
    ] as [(String, TestEvent)])
    func parses(line: String, expected: TestEvent) {
        #expect(TestEvent.parse(line) == expected)
    }

    @Test("Other output is ignored", arguments: [
        "** TEST EXECUTE SUCCEEDED **",
        "2026-10-16 13:36:07.214017+1100 Second Chance[45316:305701843] [test] ResumeLive",
        "􀄵 Testing Library Version: 1501",
        "",
    ])
    func ignores(line: String) {
        #expect(TestEvent.parse(line) == nil)
    }

    @Test("The board counts tests and keeps failures")
    func board() {
        let board = TestBoard(total: 3)
        board.apply(.started(.suite, name: "S"))
        board.apply(.started(.test, name: "a"))
        board.apply(.finished(.test, name: "a", outcome: .passed, seconds: 0.1))
        let kept = board.apply(.issue(name: "b", detail: "at X.swift:1:1: boom"))
        board.apply(.finished(.test, name: "b", outcome: .failed, seconds: 0.1))
        board.apply(.finished(.suite, name: "S", outcome: .failed, seconds: 0.2))
        #expect(kept?.contains("boom") == true)
        #expect(board.finishedCount == 2)
        #expect(abs(board.fraction - 2.0 / 3.0) < 0.001)
        #expect(board.snapshotFailures.map(\.test) == ["b"])
        #expect(board.suiteRows.map(\.name) == ["S"])
        #expect(board.suiteRows.first?.status == .failed)
        #expect(board.statusLine.hasPrefix("2/3 tests · 1 failed"))
    }

    @Test("Enumeration counts enabled tests only")
    func enumeration() {
        let json = """
        {"errors":[],"values":[{"kind":"plan","name":"P","children":[{"kind":"target","name":"T","children":[
          {"kind":"class","name":"A","disabled":true,"children":[{"kind":"test","name":"x()","disabled":true}]},
          {"kind":"class","name":"B","children":[{"kind":"test","name":"y()"},{"kind":"test","name":"z()"}]}
        ]}]}]}
        """
        #expect(TestEnumeration.countEnabledTests(json: Data(json.utf8)) == 2)
    }
}

@Suite("Project version")
struct ProjectVersionTests {
    func fixture() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "project.pbxproj", withExtension: "fixture", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Only SecondChance and WrappTemplate are rewritten")
    func rewritesVersionedTargetsOnly() throws {
        let original = try fixture()
        let rewritten = try ProjectVersion.rewrite(original, version: "9.8.7", build: "1234")
        #expect(ProjectVersion.current(in: rewritten) == "9.8.7")
        #expect(rewritten.components(separatedBy: "MARKETING_VERSION = 9.8.7;").count - 1 == 4)
        #expect(rewritten.components(separatedBy: "CURRENT_PROJECT_VERSION = 1234;").count - 1 == 4)
        // WrappPuppeteer and SecondChanceTests stay at 1.0.
        #expect(original.components(separatedBy: "MARKETING_VERSION = 1.0;").count
            == rewritten.components(separatedBy: "MARKETING_VERSION = 1.0;").count)
        // Nothing else changes.
        let changed = zip(original.components(separatedBy: "\n"), rewritten.components(separatedBy: "\n")).filter { $0 != $1 }
        #expect(changed.count == 8)
    }

    @Test("A project of a different shape is refused")
    func refusesUnexpectedShape() throws {
        let broken = try fixture().replacingOccurrences(of: "Build configuration list for PBXNativeTarget \"WrappTemplate\"", with: "Build configuration list for PBXNativeTarget \"Renamed\"")
        #expect(throws: SCError.self) { try ProjectVersion.rewrite(broken, version: "1.0.0", build: "1") }
    }

    @Test("Semantic versions", arguments: [("1.2.3", true), ("10.0.0", true), ("1.2", false), ("v1.2.3", false), ("1.2.3-beta", false)])
    func semver(value: String, valid: Bool) {
        #expect(ProjectVersion.isSemanticVersion(value) == valid)
    }
}

@Suite("Changelog")
struct ChangelogTests {
    @Test("A new section goes above the newest release, header kept")
    func insertsAboveNewest() {
        let existing = "# Changelog\n\nIntro.\n\n## 0.3.0 — 2026-09-01\n\nOld notes.\n"
        let updated = Changelog.adding(version: "0.4.0", date: "2026-10-16", notes: "### Features\n\n- New", to: existing)
        #expect(updated == "# Changelog\n\nIntro.\n\n## 0.4.0 — 2026-10-16\n\n### Features\n\n- New\n\n## 0.3.0 — 2026-09-01\n\nOld notes.\n")
        #expect(Changelog.hasSection(for: "0.3.0", in: updated))
        #expect(!Changelog.hasSection(for: "0.3", in: updated))
    }

    @Test("No changelog yet gets the default header")
    func createsFile() {
        let created = Changelog.adding(version: "0.1.0", date: "2026-01-01", notes: "- First", to: nil)
        #expect(created.hasPrefix("# Changelog\n"))
        #expect(created.hasSuffix("## 0.1.0 — 2026-01-01\n\n- First\n\n"))
    }

    @Test("A replaced section keeps the releases around it")
    func replacesBetweenReleases() {
        let existing = "# Changelog\n\nIntro.\n\n## 0.4.0 — 2026-10-01\n\nStale.\n\n## 0.3.0 — 2026-09-01\n\nOld notes.\n"
        let updated = Changelog.replacing(version: "0.4.0", date: "2026-10-20", notes: "- Fresh", in: existing)
        #expect(updated == "# Changelog\n\nIntro.\n\n## 0.4.0 — 2026-10-20\n\n- Fresh\n\n## 0.3.0 — 2026-09-01\n\nOld notes.\n")
    }

    @Test("Replacing the oldest release runs to the end of the file")
    func replacesLast() {
        let existing = "# Changelog\n\n## 0.1.0 — 2026-01-01\n\nStale.\n"
        let updated = Changelog.replacing(version: "0.1.0", date: "2026-10-20", notes: "- Fresh", in: existing)
        #expect(updated == "# Changelog\n\n## 0.1.0 — 2026-10-20\n\n- Fresh\n\n")
    }

    @Test("Only leading empty lines are trimmed from cog's notes")
    func trimsLikeSed() {
        #expect(Changelog.trimLeadingBlankLines("\n\n  indented\n- item\n\n") == "  indented\n- item")
    }
}

@Suite("Remote and re-runs")
struct RemoteTests {
    @Test("--on is taken out, but not after --")
    func extractsTarget() {
        let (target, rest) = Remote.extractTarget(from: ["test", "--on", "mac", "unit"])
        #expect(target == "mac")
        #expect(rest == ["test", "unit"])
        let (equals, _) = Remote.extractTarget(from: ["--on=mac:~/x", "app", "build"])
        #expect(equals == "mac:~/x")
        let (none, kept) = Remote.extractTarget(from: ["in-gui-session", "--", "tool", "--on", "x"])
        #expect(none == nil)
        #expect(kept == ["in-gui-session", "--", "tool", "--on", "x"])
    }

    @Test("The remote path defaults to the repo's path under home")
    func defaultsPath() {
        let root = URL(fileURLWithPath: "/Users/someone/code/second-chance")
        #expect(Remote.parse("mac", localRoot: root, home: "/Users/someone") == .init(host: "mac", path: "~/code/second-chance"))
        #expect(Remote.parse("mac:/srv/sc", localRoot: root, home: "/Users/someone") == .init(host: "mac", path: "/srv/sc"))
        #expect(Remote.parse("mac", localRoot: URL(fileURLWithPath: "/opt/sc"), home: "/Users/someone").path == "/opt/sc")
    }

    @Test("The remote command quotes every word and leaves ~ to expand")
    func quotes() {
        let command = Remote.remoteCommand(path: "~/a dir", arguments: ["wrapp", "run", "x", "--", "it's"])
        #expect(command == "cd ~/'a dir' && ./sc 'wrapp' 'run' 'x' '--' 'it'\\''s'")
    }

    @Test("Re-runs get an explicit --logs, placed before --")
    func forwardsLogs() {
        #expect(Invocation.forwarding(logs: .raw, ["wrapp", "run", "x", "--", "a"]) == ["wrapp", "run", "x", "--logs", "raw", "--", "a"])
        #expect(Invocation.forwarding(logs: .raw, ["app", "build", "--logs", "full"]) == ["app", "build", "--logs", "full"])
    }

    @Test("attach follows a run already there, so it doesn't sync")
    func attachDoesNotSync() {
        #expect(!Remote.syncs(["attach", "--list"]))
        #expect(Remote.syncs(["test", "integration"]))
    }

    @Test("The running-jobs check is valid shell and skips jobs that aren't running")
    func runningJobsCommand() throws {
        let checkout = FileManager.default.temporaryDirectory.appendingPathComponent("sc remote \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: checkout) }
        let jobs = checkout.appendingPathComponent("DerivedData/sc-jobs")
        // One finished, one never loaded in launchd: neither is running.
        try FileManager.default.createDirectory(at: jobs.appendingPathComponent("20260101-000000-1"), withIntermediateDirectories: true)
        try "0\n".write(to: jobs.appendingPathComponent("20260101-000000-1/exit-code"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: jobs.appendingPathComponent("20260101-000001-2"), withIntermediateDirectories: true)

        let command = Remote.runningJobsCommand(path: checkout.path)
        #expect(Remote.runningJobsCommand(path: "~/a dir").hasPrefix("cd ~/'a dir' 2>/dev/null && bash -c '"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "")
        #expect(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "")
    }
}

@Suite("GUI-session jobs")
struct GUISessionJobTests {
    /// A jobs dir holding finished runs with these ids.
    func jobsDir(finished ids: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-jobs-\(UUID().uuidString)")
        for id in ids {
            let job = dir.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
            try "0\n".write(to: job.appendingPathComponent("exit-code"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test("With nothing running, attach picks the newest run")
    func picksNewest() throws {
        let dir = try jobsDir(finished: ["20260101-000000-1", "20260102-000000-2"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobs = LaunchAgentJob.all(in: dir)
        #expect(try AttachCommand.pick(nil, from: jobs).id == "20260102-000000-2")
        #expect(try AttachCommand.pick("20260101", from: jobs).id == "20260101-000000-1")
        #expect(throws: SCError.self) { try AttachCommand.pick("2026", from: jobs) }
        #expect(throws: SCError.self) { try AttachCommand.pick("1999", from: jobs) }
        #expect(throws: SCError.self) { try AttachCommand.pick(nil, from: []) }
    }

    @Test("Pruning keeps the newest finished runs")
    func prunes() throws {
        let ids = (10..<22).map { "202601\($0)-000000-1" }
        let dir = try jobsDir(finished: ids)
        defer { try? FileManager.default.removeItem(at: dir) }
        LaunchAgentJob.prune(in: dir)
        #expect(LaunchAgentJob.all(in: dir).map(\.id) == Array(ids.suffix(LaunchAgentJob.keptFinished)))
    }
}

@Suite("Live region")
struct LiveRegionTests {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func write(_ value: String) { lock.withLock { text += value } }
        var output: String { lock.withLock { text } }
    }

    @Test("Slots draw in order, and redraws erase what was drawn")
    func drawsAndErases() {
        let recorder = Recorder()
        let region = LiveRegion(write: { recorder.write($0) }, size: { (80, 24) })
        let first = region.addSlot()
        let second = region.addSlot()
        first.render("one", standardPipeline: RegionAwarePipeline(region: nil))
        second.render("two\nthree", standardPipeline: RegionAwarePipeline(region: nil))
        region.printAbove("kept")
        let out = recorder.output
        #expect(out.contains("one\n"))
        // The second render came too soon after the first to draw (redraws
        // are throttled), so printing above erases the one line drawn, then
        // redraws both slots below the kept line.
        #expect(out.contains("\r\u{1B}[1A\u{1B}[J" + "kept\n" + "one\ntwo\nthree\n"))
        first.commit()
        second.remove()
        #expect(!region.isActive)
    }

    @Test("Tall regions trim the trimmable slot first, keeping its top rows")
    func trims() {
        let lines = LiveRegion.layout([(["step"], false), ((1...20).map { "row \($0)" }, true)], maxLines: 8)
        #expect(lines.count <= 8)
        #expect(lines.first == "step")
        #expect(lines[1] == "row 1")
        #expect(lines.last?.contains("more") == true)
    }

    @Test("Truncation counts visible characters, not escape codes")
    func truncates() {
        let colored = "\u{1B}[31m" + String(repeating: "x", count: 30) + "\u{1B}[0m"
        let cut = ANSI.truncate(colored, toWidth: 10)
        #expect(ANSI.strip(cut).count == 10)
        #expect(ANSI.truncate("short", toWidth: 10) == "short")
    }
}

@Suite("Games and sources")
struct GameTests {
    @Test("Slugs resolve from the app's own catalog")
    func catalog() throws {
        let game = try #require(Catalog.game(slug: "stay-tuned"))
        #expect(game.wrappName == "Nancy Drew - Stay Tuned for Danger.app")
        #expect(Games.closest(to: "stay-tund")?.slug == "stay-tuned")
        #expect(Catalog.games.count > 30)
    }

    @Test("Disk sources find images and refuse missing second disks")
    func diskSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-installers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let oneDisk = try #require(Catalog.games.first { $0.diskCount == 1 })
        let twoDisk = try #require(Catalog.games.first { $0.diskCount == 2 })
        for game in [oneDisk, twoDisk] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(game.slug), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dir.appendingPathComponent("\(game.slug)/disk-1.iso").path, contents: Data())
        }
        let repo = Repo(root: dir)
        var source = try DiskSourceOptions.parse(["--installers-dir", dir.path])
        let env = try source.environment(for: oneDisk, repo: repo)
        #expect(env["INSTALLATION_SOURCE"] == "disk")
        #expect(env["DISK_1_PATH"]?.hasSuffix("\(oneDisk.slug)/disk-1.iso") == true)
        #expect(env["DISK_2_PATH"] == nil)
        #expect(throws: SCError.self) { try source.environment(for: twoDisk, repo: repo) }
        #expect(Set(source.availableGames(repo: repo).map(\.slug)) == [oneDisk.slug, twoDisk.slug])
        source = try DiskSourceOptions.parse(["--disk", "/nonexistent.iso"])
        #expect(throws: SCError.self) { try source.environment(for: oneDisk, repo: repo) }
    }

    @Test("The Steam source names the game, and the launch choice only where there is one")
    func steamSource() throws {
        let repo = Repo(root: FileManager.default.temporaryDirectory)
        let choice = try #require(Catalog.game(slug: "shadow-ranch"))  // DRM-free
        let drm = try #require(Catalog.game(slug: "thornton-hall"))
        let notOnSteam = try #require(Catalog.game(slug: "stay-tuned"))

        let plain = try SteamSourceOptions.parse([])
        #expect(try plain.environment(for: drm, repo: repo) == ["INSTALLATION_SOURCE": "steam", "STEAM_GAME_SLUG": "thornton-hall"])
        #expect(throws: SCError.self) { try plain.environment(for: notOnSteam, repo: repo) }
        #expect(!plain.availableGames(repo: repo).contains(notOnSteam))

        let viaSteam = try SteamSourceOptions.parse(["--steam-launch", "steam"])
        #expect(try viaSteam.environment(for: choice, repo: repo)["STEAM_LAUNCH_MODE"] == "steam")
        #expect(throws: SCError.self) { try viaSteam.environment(for: drm, repo: repo) }
    }

    @Test("--source takes a list, all, and suggests a fix for a typo")
    func integrationSources() throws {
        #expect(try IntegrationOptions.parseSources("disk") == [.disk])
        #expect(try IntegrationOptions.parseSources("steam,disk") == [.disk, .steam])
        #expect(try IntegrationOptions.parseSources("all") == WrappSourceKind.allCases)
        #expect(throws: ValidationError.self) { try IntegrationOptions.parseSources("") }
        do {
            _ = try IntegrationOptions.parseSources("stam")
            Issue.record("a typo should be refused")
        } catch let error as ValidationError {
            #expect(error.message.contains("Did you mean 'steam'?"))
        }
        #expect(TestRunner.integrationSelection([.disk, .steam]).filter { $0.hasPrefix("-only-testing:") } == [
            "-only-testing:SecondChanceTests/DiskInstallIntegrationTests",
            "-only-testing:SecondChanceTests/SteamInstallIntegrationTests",
        ])
        #expect(TestRunner.unitExclusions.contains("SteamInstallIntegrationTests"))
    }

    @Test("A game tested from disk and from Steam is two rows")
    func boardBySource() throws {
        let game = try #require(Catalog.game(slug: "thornton-hall"))
        let board = GameBoard(entries: [(source: "disk", game: game), (source: "steam", game: game)])
        board.apply(ProgressRecord(event: "game", source: "steam", slug: "thornton-hall", phase: "started"))
        board.apply(ProgressRecord(event: "game", source: "steam", slug: "thornton-hall", phase: "finished", result: "passed", seconds: 9))
        #expect(board.rows.map(\.status) == ["pending", "passed"])
        // A record with no source is the disk suite's, as before.
        board.apply(ProgressRecord(event: "game", slug: "thornton-hall", phase: "finished", result: "failed"))
        #expect(board.rows.map(\.status) == ["failed", "passed"])
        // A row the suite adds itself (a second launch mode) appears as it arrives.
        board.apply(ProgressRecord(event: "game", source: "steam", slug: "haunted-mansion (via Steam)", phase: "started"))
        #expect(board.rows.map(\.slug).last == "haunted-mansion (via Steam)")
        #expect(board.statusLine.contains("haunted-mansion (via Steam) (steam)"))
    }

    @Test("Progress records decode, and junk is skipped")
    func progressRecords() {
        let record = ProgressRecord.decode(#"{"event":"game","slug":"stay-tuned","phase":"finished","result":"permission","seconds":3.5,"puppeteerExit":4}"#)
        #expect(record?.result == "permission")
        #expect(record?.puppeteerExit == 4)
        #expect(ProgressRecord.decode("not json") == nil)

        let board = GameBoard(games: [Catalog.game(slug: "stay-tuned"), Catalog.game(slug: "blue-moon")].compactMap { $0 })
        board.apply(ProgressRecord(event: "game", slug: "stay-tuned", phase: "started"))
        board.apply(ProgressRecord(event: "stage", text: "Game installing"))
        #expect(board.statusLine == "0/2 games · stay-tuned: Game installing")
        if let record { board.apply(record) }
        #expect(board.hasPermissionProblems)
        // Rows stay in catalogue order whatever their status.
        #expect(board.rows.map(\.slug) == ["stay-tuned", "blue-moon"])
        #expect(board.fraction == 0.5)
    }
}

@Suite("Build activity")
struct XcodeActivityTests {
    @Test("xcodebuild's task lines say what the build is doing", arguments: [
        (#"PhaseScriptExecution Download\ And\ Copy\ Wine\ Files /r/DerivedData/Build/Intermediates.noindex/SecondChance.build/Debug/WrappTemplate.build/Script-E2A1.sh (in target 'WrappTemplate' from project 'SecondChance')"#,
         "WrappTemplate: running “Download And Copy Wine Files”"),
        (#"SwiftCompile normal x86_64 Compiling\ LogStore.swift /r/Shared/Logging/LogStore.swift (in target 'WrappTemplate' from project 'SecondChance')"#,
         "WrappTemplate: compiling LogStore.swift"),
        (#"SwiftCompile normal arm64 /r/My\ Dir/Thing.swift (in target 'SecondChance' from project 'SecondChance')"#,
         "SecondChance: compiling Thing.swift"),
        (#"Ld /r/Second\ Chance.app/Contents/MacOS/Second\ Chance normal (in target 'SecondChance' from project 'SecondChance')"#,
         "SecondChance: linking"),
        (#"CodeSign /r/Second\ Chance.app (in target 'SecondChance' from project 'SecondChance')"#, "SecondChance: signing"),
        ("Resolve Package Graph", "Resolving packages"),
    ] as [(String, String)])
    func describes(line: String, expected: String) {
        #expect(XcodeActivity.describe(line) == expected)
    }

    @Test("Other output isn't activity", arguments: [
        "    export ARCHS=x86_64",
        "    cd /Users/x/repo",
        "🔍 Setting up Wine for SecondChance...",
        "** BUILD SUCCEEDED **",
    ])
    func ignores(line: String) {
        #expect(XcodeActivity.describe(line) == nil)
    }

    @Test("Durations read naturally")
    func durations() {
        #expect(ActivityLine.duration(41) == "41s")
        #expect(ActivityLine.duration(125) == "2m 05s")
    }
}

@Suite("Taking a run's writes back out")
struct FileRollbackTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc rollback \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func file(_ name: String, _ contents: String?) throws -> URL {
        let url = dir.appendingPathComponent(name)
        if let contents { try contents.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    static let original = (1...12).map { "line \($0);" }.joined(separator: "\n") + "\n"

    @Test("A file left as it was written goes back to the original")
    func untouched() async throws {
        let url = try file("project.pbxproj", Self.original)
        let rollback = FileRollback([url])
        try await rollback.write(Self.original.replacingOccurrences(of: "line 2;", with: "VERSION;"), to: url)
        let outcome = await rollback.restore()
        #expect(read(url) == Self.original)
        #expect(outcome.undone == [url])
        #expect(outcome.failed.isEmpty)
    }

    @Test("Other changes made after the write are kept")
    func keepsOtherChanges() async throws {
        let url = try file("project.pbxproj", Self.original)
        let rollback = FileRollback([url])
        try await rollback.write(Self.original.replacingOccurrences(of: "line 2;", with: "VERSION;"), to: url)
        // Someone edits elsewhere in the file while the build runs.
        let edited = try #require(read(url)).replacingOccurrences(of: "line 10;", with: "added file;")
        try edited.write(to: url, atomically: true, encoding: .utf8)
        let outcome = await rollback.restore()
        #expect(read(url) == Self.original.replacingOccurrences(of: "line 10;", with: "added file;"))
        #expect(outcome.failed.isEmpty)
    }

    @Test("A change to the same lines leaves the file alone and says so")
    func conflict() async throws {
        let url = try file("project.pbxproj", Self.original)
        let rollback = FileRollback([url])
        try await rollback.write(Self.original.replacingOccurrences(of: "line 2;", with: "VERSION;"), to: url)
        let edited = Self.original.replacingOccurrences(of: "line 2;", with: "OTHER;")
        try edited.write(to: url, atomically: true, encoding: .utf8)
        let outcome = await rollback.restore()
        #expect(read(url) == edited)
        #expect(outcome.failed.map(\.url) == [url])
    }

    @Test("A file the run created is removed, unless changed since")
    func created() async throws {
        let plain = try file("RELEASE_NOTES.md", nil)
        let edited = try file("CHANGELOG.md", nil)
        let rollback = FileRollback([plain, edited])
        try await rollback.write("notes\n", to: plain)
        try await rollback.write("notes\n", to: edited)
        try "notes\nmore\n".write(to: edited, atomically: true, encoding: .utf8)
        let outcome = await rollback.restore()
        #expect(!FileManager.default.fileExists(atPath: plain.path))
        #expect(read(edited) == "notes\nmore\n")
        #expect(outcome.failed.map(\.url) == [edited])
    }

    @Test("A file the run never wrote isn't touched")
    func neverWritten() async throws {
        let url = try file("CHANGELOG.md", Self.original)
        let rollback = FileRollback([url])
        try "changed by someone else\n".write(to: url, atomically: true, encoding: .utf8)
        let outcome = await rollback.restore()
        #expect(read(url) == "changed by someone else\n")
        #expect(outcome.undone.isEmpty && outcome.failed.isEmpty)
    }
}

@Suite("Release notes")
struct ReleaseNotesTests {
    @Test("Sections come out in a fixed order, internal changes collapsed")
    func layout() {
        let rewrite = ReleaseNotes.Rewrite(
            sections: [
                .init(heading: "Fixed", items: ["- Games no longer freeze"]),
                .init(heading: "New", items: ["Steam games", " "]),
                .init(heading: "Fixed", items: ["Sound works again"]),
            ],
            internalChanges: ["sc release signs updates"]
        )
        #expect(ReleaseNotes.markdown(rewrite) == """
        ### New

        - Steam games

        ### Fixed

        - Games no longer freeze
        - Sound works again

        <details>
        <summary>Behind the scenes</summary>

        - sc release signs updates

        </details>
        """)
    }

    @Test("No internal changes means no details block")
    func noInternal() {
        let notes = ReleaseNotes.markdown(.init(sections: [.init(heading: "Improved", items: ["Faster"])], internalChanges: []))
        #expect(notes == "### Improved\n\n- Faster")
    }

    @Test("The update window gets everything but the details")
    func updateWindow() {
        let notes = "### Fixed\n\n- A fix\n\n<details>\n<summary>Behind the scenes</summary>\n\n- Tooling\n\n</details>\n"
        #expect(ReleaseNotes.forUpdateWindow(notes) == "### Fixed\n\n- A fix")
        #expect(ReleaseNotes.forUpdateWindow("<details>\n\n- Only tooling\n\n</details>").hasPrefix("Behind-the-scenes"))
        #expect(ReleaseNotes.forUpdateWindow("### Features\n\n- Plain cog notes") == "### Features\n\n- Plain cog notes")
    }
}
