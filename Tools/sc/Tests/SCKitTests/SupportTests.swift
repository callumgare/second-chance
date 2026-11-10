import ArgumentParser
import Foundation
import Testing
@testable import SCKit
import WrappBuilder

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
        let broken = try fixture().replacingOccurrences(of: "Build configuration list for PBXNativeTarget \"WrappTemplate\"",
                                                        with: "Build configuration list for PBXNativeTarget \"Renamed\"")
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

    @Test("A section reads back as the notes it was written with")
    func readsSection() {
        let notes = "### New\n\n- Updates\n\n<details>\n<summary>Behind the scenes</summary>\n\n- Tooling\n\n</details>"
        let text = Changelog.adding(version: "0.4.0", date: "2026-10-20", notes: notes,
                                    to: "# Changelog\n\n## 0.3.0 — 2026-09-01\n\nOld notes.\n")
        #expect(Changelog.section(for: "0.4.0", in: text) == notes)
        #expect(Changelog.section(for: "0.3.0", in: text) == "Old notes.")
        #expect(Changelog.section(for: "0.5.0", in: text) == nil)
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

    @Test("A GUI login session is told from launchctl's print of the domain")
    func loginSession() {
        #expect(GUISession.isLoginSession(launchctlPrint: "gui/502 = {\n\ttype = login\n\thandle = 100539\n"))
        #expect(!GUISession.isLoginSession(launchctlPrint: "gui/502 = {\n\ttype = user\n"))
        #expect(!GUISession.isLoginSession(launchctlPrint: ""))
    }

    @Test("Only this user's session being locked counts, not another's left in the background")
    func screenLockIsThisUsers() throws {
        let sessions: [[String: Any]] = [
            ["kCGSSessionUserIDKey": 501, "kCGSSessionOnConsoleKey": true],
            ["kCGSSessionUserIDKey": 502, "kCGSSessionOnConsoleKey": false, "CGSSessionScreenIsLocked": true],
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: ["IOConsoleUsers": sessions], format: .xml, options: 0)
        #expect(!GUISession.isScreenLocked(ioregPlist: plist, uid: 501))
        #expect(GUISession.isScreenLocked(ioregPlist: plist, uid: 502))
        #expect(!GUISession.isScreenLocked(ioregPlist: Data(), uid: 501))
    }

    @Test("attach follows a run already there, so it doesn't sync")
    func attachDoesNotSync() {
        #expect(!Remote.syncs(["attach", "--list"]))
        #expect(Remote.syncs(["test", "integration"]))
    }

    @Test("A buildless command sends nothing when the copy's sc is this one, and its sc alone beside a run")
    func syncPlan() {
        let idle = Remote.Probe(stamp: "100 5", runningJobs: [])
        let busy = Remote.Probe(stamp: "100 5", runningJobs: ["20261106-142527-35988"])
        #expect(Remote.syncPlan(arguments: ["session", "list"], probe: idle, localStamp: "100 5") == .nothing)
        #expect(Remote.syncPlan(arguments: ["session", "list"], probe: busy, localStamp: "100 5") == .nothing)
        #expect(Remote.syncPlan(arguments: ["session", "list"], probe: idle, localStamp: "200 6") == .sync)
        #expect(Remote.syncPlan(arguments: ["session", "list"], probe: busy, localStamp: "200 6") == .binaryBeside)
        #expect(Remote.syncPlan(arguments: ["session", "list"], probe: Remote.Probe(stamp: nil, runningJobs: []), localStamp: "1 1") == .sync)
        // A command that needs the build syncs it, into a snapshot beside a run.
        #expect(Remote.syncPlan(arguments: ["wrapp", "run", "x"], probe: idle, localStamp: "100 5") == .sync)
        #expect(Remote.syncPlan(arguments: ["wrapp", "run", "x"], probe: busy, localStamp: "100 5") == .snapshot)
    }

    @Test("The probe reads the copy's sc's stamp and its running jobs")
    func probe() throws {
        #expect(Remote.parseProbe("sc-binary 123 456\njob-1\n\njob-2\n") == Remote.Probe(stamp: "123 456", runningJobs: ["job-1", "job-2"]))
        #expect(Remote.parseProbe("") == Remote.Probe(stamp: nil, runningJobs: []))

        // Run against a copy whose sc is a known file, it prints that file's stamp.
        let checkout = FileManager.default.temporaryDirectory.appendingPathComponent("sc probe \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: checkout) }
        let binary = checkout.appendingPathComponent(".sc/sc")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not really sc".write(to: binary, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Remote.probeCommand(path: checkout.path)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(Remote.parseProbe(result) == Remote.Probe(stamp: try RuntimeCopy.stamp(of: binary), runningJobs: []))
    }

    @Test("A binary sent beside a run runs with the copy as its root")
    func remoteCommandWithBinaryBeside() {
        let path = RuntimeCopy.versionPath(stamp: "123 456")
        #expect(path == ".sc/versions/123-456/sc")
        #expect(Remote.remoteCommand(path: "~/sc", arguments: ["session", "list"], executable: path)
            == "cd ~/'sc' && env SC_REPO_ROOT=\"$PWD\" '.sc/versions/123-456/sc' 'session' 'list'")
        #expect(Remote.remoteCommand(path: "~/sc", arguments: ["session", "list"]) == "cd ~/'sc' && ./sc 'session' 'list'")
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

@Suite("Build status line")
struct BuildStatusLineTests {
    @Test("A step's figures follow its stage, and go when the stage changes")
    func figures() {
        let status = BuildStatusLine(label: "Building X")
        #expect(status.line(after: ProgressRecord(event: "stage", text: "Downloading through Steam")) == "Building X — Downloading through Steam")
        #expect(status.line(after: ProgressRecord(event: "step-progress", text: "1.2 GB of 2.4 GB"))
            == "Building X — Downloading through Steam (1.2 GB of 2.4 GB)")
        #expect(status.line(after: ProgressRecord(event: "stage", text: "Checking the download")) == "Building X — Checking the download")
        #expect(status.line(after: ProgressRecord(event: "step-progress")) == "Building X — Checking the download")
        #expect(status.line(after: ProgressRecord(event: "completed")) == nil)
    }
}

/// This checkout, whose bundles the installers store is laid out by.
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite("Games and sources")
struct GameTests {
    @Test("Slugs resolve from the app's own catalog")
    func catalog() throws {
        let game = try #require(Catalog.game(slug: "stay-tuned"))
        #expect(game.wrappName == "Nancy Drew - Stay Tuned for Danger.app")
        #expect(Games.closest(to: "stay-tund")?.slug == "stay-tuned")
        #expect(Catalog.games.count > 30)
    }

    @Test("A program is named by its bundle id, or by what follows its slash when only one id ends so")
    func programByBundleID() throws {
        #expect(Games.matching("nancy-drew/blue-moon").map(\.programID) == ["nancy-drew/blue-moon"])
        #expect(Games.matching("blue-moon").map(\.programID) == ["nancy-drew/blue-moon"])
        #expect(Games.matching("freeware/laser-tank").map(\.programID) == ["freeware/laser-tank"])
        #expect(Games.matching("lue-moon").isEmpty)
        #expect(Games.matching("nancy-drew/nonexistent").isEmpty)
        #expect(Games.closest(to: "nancy-drew/blu-moon")?.programID == "nancy-drew/blue-moon")

        let games = try ["nancy-drew/blue-moon", "freeware/laser-tank"].map { try #require(Games.matching($0).first) }
        let twin = CatalogGame(slug: "blue-moon-2", title: "Twin", diskCount: 0, engine: "wine", isOnSteam: false,
                               offersSteamLaunchChoice: false, isOnBigFish: false, wrappName: "Twin.app", programID: "other/blue-moon")
        #expect(Games.matching("blue-moon", in: games + [twin]).count == 2)
        #expect(Games.matching("other/blue-moon", in: games + [twin]) == [twin])
    }

    @Test("With --bundle and no program named, the program is the bundle's, or one of theirs")
    func programFromExtraBundles() throws {
        let ui = UI(environment: TerminalEnvironment(isInteractive: false, isColored: false, canReadKeys: false),
                    mode: .raw, logsDir: FileManager.default.temporaryDirectory)
        let laserTank = try Games.resolve(nil, candidates: [], candidateKind: "a disc", command: "wrapp build", ui: ui,
                                          extras: ["freeware/laser-tank"])
        #expect(laserTank.programID == "freeware/laser-tank")
        // A program named wins over --bundle's.
        let blueMoon = try Games.resolve("blue-moon", candidates: [], candidateKind: "a disc", command: "wrapp build", ui: ui,
                                         extras: ["freeware/laser-tank"])
        #expect(blueMoon.programID == "nancy-drew/blue-moon")
        // Several, with nobody to ask, says to name one.
        #expect(throws: SCError.self) {
            try Games.resolve(nil, candidates: [], candidateKind: "a disc", command: "wrapp build", ui: ui,
                              extras: ["freeware/laser-tank", "nancy-drew/blue-moon"])
        }
    }

    @Test("--bundle names a folder holding a manifest, from the working directory unless absolute, or a shipped bundle's id")
    func extraBundleFolders() throws {
        let shipped = repoRoot.appendingPathComponent("Bundles")
        #expect(try ExtraBundleOptions.resolve("Bundles/freeware/skifree", cwd: repoRoot, shipped: shipped)
            == .folder(repoRoot.appendingPathComponent("Bundles/freeware/skifree").standardizedFileURL))
        #expect(try ExtraBundleOptions.resolve("freeware/skifree", cwd: repoRoot, shipped: shipped) == .shipped("freeware/skifree"))
        #expect(throws: SCError.self) { try ExtraBundleOptions.resolve("Bundles/freeware", cwd: repoRoot, shipped: shipped) }
        #expect(throws: SCError.self) { try ExtraBundleOptions.resolve("freeware/nonexistent", cwd: repoRoot, shipped: shipped) }
    }

    @Test("Disk sources find images in the store and refuse missing second disks")
    func diskSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-installers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let oneDisk = try #require(Catalog.game(slug: "old-clock"))
        let twoDisk = try #require(Catalog.game(slug: "secrets-can-kill"))
        #expect(oneDisk.diskCount == 1 && twoDisk.diskCount == 2)
        for game in [oneDisk, twoDisk] {
            let edition = dir.appendingPathComponent("\(game.programID)/cd")
            try FileManager.default.createDirectory(at: edition, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: edition.appendingPathComponent("disc-1.iso").path, contents: Data())
        }
        let repo = Repo(root: repoRoot, installers: InstallersStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("sc-none")))
        var source = try DiskSourceOptions.parse(["--installers-dir", dir.path])
        let env = try source.environment(for: oneDisk, repo: repo)
        #expect(env["INSTALLATION_SOURCE"] == "disk")
        #expect(env["DISK_1_PATH"]?.hasSuffix("\(oneDisk.programID)/cd/disc-1.iso") == true)
        #expect(env["DISK_2_PATH"] == nil)
        #expect(throws: SCError.self) { try source.environment(for: twoDisk, repo: repo) }
        #expect(source.availableGames(repo: repo).map(\.slug) == [oneDisk.slug])
        FileManager.default.createFile(atPath: dir.appendingPathComponent("\(twoDisk.programID)/cd/disc-2.iso").path, contents: Data())
        #expect(try source.environment(for: twoDisk, repo: repo)["DISK_2_PATH"]?.hasSuffix("/cd/disc-2.iso") == true)
        source = try DiskSourceOptions.parse(["--disk", "/nonexistent.iso"])
        #expect(throws: SCError.self) { try source.environment(for: oneDisk, repo: repo) }
    }

    @Test("Without --from, a game builds from the first source it has, preferring one whose installer is in the store")
    func defaultSource() throws {
        let laserTank = try #require(Catalog.game(slug: "laser-tank"))
        let whiteWolf = try #require(Catalog.game(slug: "white-wolf"))
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("sc-default-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        let repo = Repo(root: repoRoot, installers: InstallersStore(root: store))
        let options = try WrappSourceOptions.parse([])
        #expect(options.kind(for: laserTank, repo: repo) == .download)
        #expect(options.kind(for: whiteWolf, repo: repo) == .disk)

        let her = store.appendingPathComponent("\(whiteWolf.programID)/her-windows")
        try FileManager.default.createDirectory(at: her, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: her.appendingPathComponent("installer.exe").path, contents: Data())
        #expect(options.kind(for: whiteWolf, repo: repo) == .herDownload)

        #expect(try WrappSourceOptions.parse(["--from", "steam"]).kind(for: whiteWolf, repo: repo) == .steam)
        #expect(try WrappSourceOptions.parse(["--big-fish-trial"]).kind(for: whiteWolf, repo: repo) == .bigFish)
        #expect(try WrappSourceOptions.parse(["--disk", "/x.iso"]).kind(for: laserTank, repo: repo) == .disk)
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

    @Test("The Her download source finds the game's download, and asks which when there are two")
    func herDownloadSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sc-her-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = Repo(root: repoRoot, installers: InstallersStore(root: root))
        let windows = try #require(Catalog.game(slug: "scarlet-hand"))
        let both = try #require(Catalog.game(slug: "trail-of-the-twister"))
        let none = try #require(Catalog.game(slug: "stay-tuned"))
        for path in ["nancy-drew/scarlet-hand/her-windows/installer.exe", "nancy-drew/scarlet-hand/cd/disc-1.iso",
                     "nancy-drew/trail-of-the-twister/her-mac/installer.dmg", "nancy-drew/trail-of-the-twister/her-windows/installer.exe"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }

        let source = try HerDownloadSourceOptions.parse([])
        let env = try source.environment(for: windows, repo: repo)
        #expect(env["INSTALLATION_SOURCE"] == "her-download")
        #expect(env["HER_INSTALLER_PATH"]?.hasSuffix("scarlet-hand/her-windows/installer.exe") == true)
        #expect(throws: SCError.self) { try source.environment(for: both, repo: repo) }
        #expect(throws: SCError.self) { try source.environment(for: none, repo: repo) }
        #expect(Games.herDownloads(for: both, repo: repo).map(\.format) == ["windows", "mac"])
        #expect(Set(source.availableGames(repo: repo).map(\.slug)) == [windows.slug, both.slug])
    }

    @Test("The Big Fish source names the game, and signs in with .env's test account unless it's a trial")
    func bigFishSource() throws {
        let repo = Repo(root: FileManager.default.temporaryDirectory.appendingPathComponent("sc-big-fish-\(UUID().uuidString)"))
        let onBigFish = try #require(Catalog.game(slug: "white-wolf"))
        let notOnBigFish = try #require(Catalog.game(slug: "stay-tuned"))
        let account = ["BIG_FISH_EMAIL": "player@example.com", "BIG_FISH_PASSWORD": "secret", "SENTRY_DSN": "x"]

        let owned = try BigFishSourceOptions.parse([])
        #expect(try owned.environment(for: onBigFish, dotEnv: account) == [
            "INSTALLATION_SOURCE": "big-fish", "BIG_FISH_GAME_SLUG": "white-wolf",
            "BIG_FISH_TEST_SIGN_IN": "1", "BIG_FISH_EMAIL": "player@example.com", "BIG_FISH_PASSWORD": "secret",
        ])
        // No account in .env: a headless build couldn't sign in.
        #expect(throws: SCError.self) { try owned.environment(for: onBigFish, dotEnv: ["BIG_FISH_EMAIL": "player@example.com"]) }
        #expect(throws: SCError.self) { try owned.environment(for: onBigFish, repo: repo) }
        #expect(throws: SCError.self) { try owned.environment(for: notOnBigFish, dotEnv: account) }
        #expect(owned.availableGames(repo: repo).contains(onBigFish))
        #expect(!owned.availableGames(repo: repo).contains(notOnBigFish))

        let trial = try BigFishSourceOptions.parse(["--big-fish-trial"])
        #expect(try trial.environment(for: onBigFish, repo: repo) == [
            "INSTALLATION_SOURCE": "big-fish", "BIG_FISH_GAME_SLUG": "white-wolf", "BIG_FISH_TRIAL": "1",
        ])
        #expect(try trial.environment(for: onBigFish, dotEnv: account)["BIG_FISH_PASSWORD"] == nil)

        let options = try WrappSourceOptions.parse(["--from", "big-fish", "--big-fish-trial"])
        #expect(options.input(for: onBigFish, repo: repo) is BigFishSourceOptions)
        #expect(try options.input(for: onBigFish, repo: repo).environment(for: onBigFish, repo: repo)["BIG_FISH_TRIAL"] == "1")
    }

    @Test("The Big Fish suites test the games Big Fish sells, and only the owned one gets the account")
    func bigFishIntegration() throws {
        let onBigFish = try #require(Catalog.game(slug: "white-wolf"))
        let notOnBigFish = try #require(Catalog.game(slug: "stay-tuned"))
        for source in [IntegrationSource.bigFish, .bigFishTrial] {
            #expect(source.tests(onBigFish, discs: [], herDownloads: [], downloads: []))
            #expect(!source.tests(notOnBigFish, discs: [], herDownloads: [], downloads: []))
        }
        #expect(Catalog.games.filter { IntegrationSource.bigFishTrial.tests($0, discs: [], herDownloads: [], downloads: []) }.count == 30)

        #expect(try IntegrationOptions.parseSources("big-fish-trial") == [.bigFishTrial])
        #expect(try IntegrationOptions.parseSources("big-fish,disk,big-fish-trial") == [.disk, .bigFish, .bigFishTrial])
        #expect(TestRunner.integrationSelection([.bigFish, .bigFishTrial]).filter { $0.hasPrefix("-only-testing:") } == [
            "-only-testing:SecondChanceTests/BigFishOwnedInstallIntegrationTests",
            "-only-testing:SecondChanceTests/BigFishTrialInstallIntegrationTests",
        ])
        for source in [IntegrationSource.bigFish, .bigFishTrial] {
            #expect(TestRunner.unitExclusions.contains(TestRunner.integrationSuite(source)))
        }

        let dotEnv = ["BIG_FISH_EMAIL": "player@example.com", "BIG_FISH_PASSWORD": "secret", "SENTRY_DSN": "x"]
        #expect(TestRunner.bigFishEnvironment(dotEnv: dotEnv, sources: [.bigFish]) == [
            "TEST_RUNNER_BIG_FISH_EMAIL": "player@example.com", "TEST_RUNNER_BIG_FISH_PASSWORD": "secret",
        ])
        #expect(TestRunner.bigFishEnvironment(dotEnv: dotEnv, sources: [.disk, .bigFishTrial]).isEmpty)
        #expect(TestRunner.bigFishEnvironment(dotEnv: [:], sources: [.bigFish]).isEmpty)
    }

    @Test("--keep-recordings keeps every launch's recording, for longer")
    func keepRecordings() throws {
        #expect(try IntegrationOptions.parse(["--keep-recordings"]).keepRecordings)
        #expect(try !IntegrationOptions.parse([]).keepRecordings)
        #expect(TestRunner.recordingEnvironment(keepRecordings: true) == [
            "TEST_RUNNER_KEEP_RECORDINGS": "1", "TEST_RUNNER_RECORDING_LIMIT": "300",
        ])
        #expect(TestRunner.recordingEnvironment(keepRecordings: false).isEmpty)
    }

    @Test("--build-concurrency defaults to one build per four performance cores, never none")
    func defaultBuildConcurrency() throws {
        #expect(IntegrationOptions.defaultBuildConcurrency(fastCores: 8) == 2)
        #expect(IntegrationOptions.defaultBuildConcurrency(fastCores: 6) == 1)
        #expect(IntegrationOptions.defaultBuildConcurrency(fastCores: 12) == 3)
        #expect(IntegrationOptions.defaultBuildConcurrency(fastCores: 2) == 1)
        #expect(try IntegrationOptions.parse(["--build-concurrency", "3"]).resolvedBuildConcurrency == 3)
    }

    @Test("--source takes a list, all, and suggests a fix for a typo")
    func integrationSources() throws {
        #expect(try IntegrationOptions.parseSources("her-download,disk") == [.disk, .herDownload])
        #expect(try IntegrationOptions.parseSources("disk") == [.disk])
        #expect(try IntegrationOptions.parseSources("steam,disk") == [.disk, .steam])
        #expect(try IntegrationOptions.parseSources("all") == IntegrationSource.allCases)
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
        let record = ProgressRecord.decode(#"{"event":"game","slug":"stay-tuned","phase":"finished","result":"failed","seconds":3.5,"puppeteerExit":1}"#)
        #expect(record?.result == "failed")
        #expect(record?.puppeteerExit == 1)
        #expect(ProgressRecord.decode("not json") == nil)

        let board = GameBoard(games: [Catalog.game(slug: "stay-tuned"), Catalog.game(slug: "blue-moon")].compactMap { $0 })
        board.apply(ProgressRecord(event: "game", slug: "stay-tuned", phase: "started"))
        board.apply(ProgressRecord(event: "stage", text: "Game installing"))
        #expect(board.statusLine == "0/2 games · stay-tuned: Game installing")
        if let record { board.apply(record) }
        #expect(board.rows.first?.status == "failed")
        // Rows stay in catalogue order whatever their status.
        #expect(board.rows.map(\.slug) == ["stay-tuned", "blue-moon"])
        #expect(board.fraction == 0.5)
    }
}

@Suite("Build activity")
struct XcodeActivityTests {
    @Test("xcodebuild's task lines say what the build is doing", arguments: [
        // swiftlint:disable:next line_length
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
        #expect(DurationText.text(0) == "0s")
        #expect(DurationText.text(60) == "1m 00s")
        #expect(DurationText.text(2798.4) == "46m 38s")
        #expect(DurationText.text(3600) == "1h 00m 00s")
        #expect(DurationText.text(3998.6) == "1h 06m 39s")
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

    @Test("Claude Code's stream says what it's doing", arguments: [
        (#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git show 1a2b3c"}}]}}"#, "Running git show 1a2b3c"),
        (#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/repo/docs/steam.md"}}]}}"#, "Reading steam.md"),
        (#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"…"},{"type":"tool_use","name":"Grep","input":{"pattern":"Steam"}}]}}"#, "Searching for Steam"),
        (#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"StructuredOutput","input":{}}]}}"#, "Writing the notes"),
        (#"{"type":"assistant","message":{"content":[{"type":"text","text":"Let me look."}]}}"#, "Thinking"),
    ])
    func streamActivity(line: String, expected: String) {
        guard case .activity(let text) = ReleaseNotes.StreamEvent(line: line) else {
            Issue.record("No activity in \(line)")
            return
        }
        #expect(text == expected)
    }

    @Test("The stream's result carries the notes; other lines are ignored")
    func streamResult() throws {
        let line = #"{"type":"result","is_error":false,"structured_output":{"sections":[{"heading":"Fixed","items":["Sound works"]}],"internalChanges":[]}}"#
        guard case .result(let reply) = ReleaseNotes.StreamEvent(line: line) else {
            Issue.record("No result")
            return
        }
        #expect(reply.structured_output == .init(sections: [.init(heading: "Fixed", items: ["Sound works"])], internalChanges: []))
        #expect(ReleaseNotes.StreamEvent(line: #"{"type":"system","subtype":"init"}"#) == nil)
        #expect(ReleaseNotes.StreamEvent(line: #"{"type":"user","message":{"content":[]}}"#) == nil)
        #expect(ReleaseNotes.StreamEvent(line: "Error: not logged in") == nil)
    }
}

@Suite("Local settings (.env)")
struct DotEnvTests {
    @Test("Lines read as a shell would: comments, export, quotes, last one wins")
    func parses() {
        let values = DotEnv.parse("""
            # The DSN
            SENTRY_DSN="https://key@o1.ingest.sentry.io/2"
            export SENTRY_ORG = 'nancy'
            SENTRY_PROJECT=first
            SENTRY_PROJECT=second-chance

            EMPTY=
            not a setting
            """)
        #expect(values["SENTRY_DSN"] == "https://key@o1.ingest.sentry.io/2")
        #expect(values["SENTRY_ORG"] == "nancy")
        #expect(values["SENTRY_PROJECT"] == "second-chance")
        #expect(values["EMPTY"] == "")
        #expect(values.count == 4)
    }

    @Test("Hiding the test host's windows reaches it only when set")
    func hideTestUI() {
        #expect(TestRunner.hostEnvironment(dotEnv: ["SECOND_CHANCE_HIDE_TEST_UI": "1", "SENTRY_DSN": "x"])
            == ["TEST_RUNNER_SECOND_CHANCE_HIDE_TEST_UI": "1"])
        #expect(TestRunner.hostEnvironment(dotEnv: ["SECOND_CHANCE_HIDE_TEST_UI": ""]).isEmpty)
        #expect(TestRunner.hostEnvironment(dotEnv: [:]).isEmpty)
    }

    @Test("--on sends the runtime copy's folders and nothing else of the checkout")
    func syncFilters() throws {
        let filters = Remote.syncFilters(for: ["test", "integration", "old-clock"])
        #expect(filters.contains("/Bundles/") && filters.contains("/Modules/") && filters.contains("/TestFixtures/"))
        // rsync takes the first rule that matches: Release's products are left
        // out before the products are let in, and they before the catch-all.
        let release = try #require(filters.firstIndex(of: "/DerivedData/Build/Products/Release/"))
        let products = try #require(filters.firstIndex(of: "/DerivedData/Build/Products/"))
        #expect(release < products)
        #expect(filters.suffix(2) == ["--exclude", "/*"])
        // A command that runs nothing there gets no build.
        #expect(!Remote.syncFilters(for: ["session", "claim"]).contains("/DerivedData/Build/Products/"))
    }

    @Test("--on sends this Mac's installers store to the other Mac's, links as links, never deleting what's there")
    func installersSync() {
        let sync = Remote.installersSync(from: URL(fileURLWithPath: "/stores/installers"), host: "mac")
        #expect(sync.suffix(2) == ["/stores/installers/", "mac:/Users/Shared/second-chance/installers/"])
        #expect(!sync.contains("--delete"))
        #expect(sync.first == "-rl")
        // Another user's files in the shared store: no times or attributes to set, and no Finder litter.
        #expect(!sync.contains("-aE") && sync.contains("--size-only"))
        #expect(sync.contains(".DS_Store"))
        // One at a time per Mac, behind a lock any user can take.
        #expect(sync.contains("--rsync-path=/usr/bin/lockf -k /tmp/second-chance-installers-sync.lock /usr/bin/rsync"))
    }

    @Test("A command that would build first builds here, and runs there with --skip-app-build")
    func buildsHere() {
        #expect(Remote.localBuild(for: ["test", "integration", "old-clock"]) == .tests)
        #expect(Remote.localBuild(for: ["wrapp", "build", "old-clock"]) == .app)
        #expect(Remote.localBuild(for: ["test", "integration", "--skip-app-build"]) == nil)
        #expect(Remote.localBuild(for: ["session", "claim"]) == nil)
        #expect(Remote.skippingAppBuild(["wrapp", "run", "x", "--", "-a"]) == ["wrapp", "run", "x", "--skip-app-build", "--", "-a"])
    }

    @Test("Commands that work on the sources aren't sent to a runtime copy")
    func needsSources() {
        #expect(Remote.needsSources(["lint"]))
        #expect(Remote.needsSources(["app", "build"]))
        #expect(Remote.needsSources(["test", "unit"]))
        #expect(!Remote.needsSources(["app", "run"]))
        #expect(!Remote.needsSources(["test", "integration"]))
        #expect(!Remote.needsSources(["puppet", "start", "x"]))
    }

    @Test("A sync that stops partway says so, keeping its status")
    func syncFailure() {
        let failure = Remote.syncFailure(host: "mac", rawTarget: "mac:~/sc", arguments: ["test", "--skip-app-build"], status: 23)
        #expect(failure.exitCode == 23)
        #expect(!failure.alreadyReported)
    }

    @Test("A sync that loses its connection says so, not that files changed")
    func syncFailureByStatus() {
        let hint = { (status: Int32) in Remote.syncFailure(host: "mac", rawTarget: "mac", arguments: [], status: status).hints.joined() }
        #expect(hint(255).contains("connection to mac"))
        #expect(hint(12).contains("connection to mac"))
        #expect(hint(24).contains("vanished"))
        #expect(!hint(255).contains("changed"))
    }
}

@Suite("Test VMs")
struct TestVMTests {
    @Test("tart's VM list maps names to states")
    func parseList() {
        let json = """
        [
          { "Name" : "sc-sequoia", "Running" : false, "State" : "stopped", "Source" : "local" },
          { "Name" : "sc-tahoe", "Running" : true, "State" : "running", "Source" : "local" },
          { "Name" : "no-state", "Running" : true, "Source" : "local" }
        ]
        """
        #expect(TestVM.parseList(json) == ["sc-sequoia": "stopped", "sc-tahoe": "running", "no-state": "running"])
        #expect(TestVM.parseList("not json").isEmpty)
    }

    @Test("A prepared VM reaches the tests as TEST_RUNNER_ variables")
    func testEnvironment() {
        let withKey = TestVM.Prepared(name: "sc-sequoia", target: "admin@192.168.64.2", sshKey: "/keys/vm", startedHere: true)
        #expect(withKey.testEnvironment == ["TEST_RUNNER_VM_NAME": "sc-sequoia", "TEST_RUNNER_VM_SSH_TARGET": "admin@192.168.64.2",
                                            "TEST_RUNNER_VM_SSH_KEY": "/keys/vm"])
        let without = TestVM.Prepared(name: "sc-sequoia", target: "admin@192.168.64.2", sshKey: nil, startedHere: false)
        #expect(without.testEnvironment["TEST_RUNNER_VM_SSH_KEY"] == nil)
    }

    @Test("Games building side by side each keep their own stage, and the launching one leads the status line")
    func boardWithGamesSideBySide() {
        let board = GameBoard(games: ["stay-tuned", "blue-moon", "old-clock"].compactMap { Catalog.game(slug: $0) })
        board.apply(ProgressRecord(event: "game", slug: "stay-tuned", phase: "started"))
        board.apply(ProgressRecord(event: "game", slug: "blue-moon", phase: "started"))
        board.apply(ProgressRecord(event: "stage", text: "Game installing", source: "disk", slug: "stay-tuned"))
        board.apply(ProgressRecord(event: "stage", text: "Copying the disc", source: "disk", slug: "blue-moon"))
        #expect(board.rows.map(\.stage) == ["Game installing", "Copying the disc", nil])
        #expect(board.statusLine == "0/3 games · blue-moon: Copying the disc · also running: stay-tuned")

        board.apply(ProgressRecord(event: "game", slug: "stay-tuned", phase: "launching"))
        #expect(board.statusLine == "0/3 games · stay-tuned: launching · also running: blue-moon")

        // A finished game's late stage line doesn't bring it back.
        board.apply(ProgressRecord(event: "game", slug: "blue-moon", phase: "finished", result: "passed", seconds: 9))
        board.apply(ProgressRecord(event: "stage", text: "Saving", source: "disk", slug: "blue-moon"))
        #expect(board.rows[1].stage == nil)
        #expect(board.statusLine == "1/3 games · stay-tuned: launching")
    }

    @Test("The table charges a game for its own build and launch, and shows waiting apart")
    func tableSplitsTheTime() throws {
        let board = GameBoard(games: ["stay-tuned", "blue-moon"].compactMap { Catalog.game(slug: $0) })
        let record = try #require(ProgressRecord.decode(
            #"{"event":"game","slug":"stay-tuned","phase":"finished","result":"passed","seconds":200,"#
            + #""buildSeconds":120,"launchSeconds":30,"queuedSeconds":50,"peakBytes":3500000000}"#
        ))
        board.apply(record)
        #expect(board.peakBytes == ["disk/stay-tuned": 3_500_000_000])
        let table = TestRunner.gameTable(board, showSource: false)
        #expect(table.headers == ["Game", "Engine", "Result", "Build", "Launch", "Waited", "Disk"])
        #expect(table.rows[0].count == 7)

        let unwaited = GameBoard(games: ["blue-moon"].compactMap { Catalog.game(slug: $0) })
        unwaited.apply(ProgressRecord(event: "game", slug: "blue-moon", phase: "finished", result: "passed", seconds: 9))
        #expect(TestRunner.gameTable(unwaited, showSource: false).headers == ["Game", "Engine", "Result", "Build", "Launch"])
    }

    @Test("A finished game's warnings are kept on its row")
    func gameWarnings() throws {
        let board = GameBoard(games: ["stay-tuned"].compactMap { Catalog.game(slug: $0) })
        board.apply(try #require(ProgressRecord.decode(
            #"{"event":"game","slug":"stay-tuned","phase":"finished","result":"passed","seconds":20,"warnings":["No splash screen was recognised"]}"#
        )))
        #expect(board.rows[0].warnings == ["No splash screen was recognised"])
        #expect(board.rows[0].status == "passed")
    }

    @Test("Each game's largest build size is kept between runs")
    func integrationSizesKeepTheLargest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-sizes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sizes = IntegrationSizes(testResults: dir)
        #expect(sizes.load().isEmpty)
        try sizes.record(["disk/stay-tuned": 300, "disk/blue-moon": 100])
        try sizes.record(["disk/stay-tuned": 200, "steam/blue-moon": 50])
        #expect(sizes.load() == ["disk/stay-tuned": 300, "disk/blue-moon": 100, "steam/blue-moon": 50])
    }
}

@Suite("Leaked Safari helpers")
struct LeakedHelpersTests {
    static let path = "/System/Library/PrivateFrameworks/SafariPlatformSupport.framework/Versions/A/XPCServices/"
        + "com.apple.SafariPlatformSupport.Helper.xpc/Contents/MacOS/com.apple.SafariPlatformSupport.Helper"

    @Test("Helpers are found in a process listing, by pid")
    func findsHelpers() {
        let listing = ["    1 /sbin/launchd", "  999 /Applications/Safari.app/Contents/MacOS/Safari",
                       "  120 \(Self.path)", "  100 \(Self.path)"].joined(separator: "\n")
        #expect(LeakedHelpers.pids(listing: listing) == [100, 120])
    }

    @Test("Before a run, all but the newest few are ended once there are more than a Mac in use has")
    func endsAllButNewest() {
        #expect(LeakedHelpers.toEnd(Array(100..<125)) == Array(100..<120))
    }

    @Test("Before a run, a few are left alone")
    func leavesAFew() {
        #expect(LeakedHelpers.toEnd(Array(100..<110)).isEmpty)
    }
}

@Suite("Test users' signing certificate")
struct SigningIdentityTests {
    @Test("Only an Apple Development identity counts as one the project can sign with")
    func hasDevelopment() {
        let mine = """
          1) 35E94C0D29115DD25A212BCD3F7039311005129F "Apple Development: someone@example.com (ABCDE12345)"
             1 valid identities found
        """
        #expect(SigningIdentity.hasDevelopment(findIdentityOutput: mine))
        #expect(!SigningIdentity.hasDevelopment(findIdentityOutput: "     0 valid identities found\n"))
        #expect(!SigningIdentity.hasDevelopment(findIdentityOutput: "  1) 00AA \"Developer ID Application: Someone (ABCDE12345)\"\n"))
    }

    /// Runs a script as `ssh … bash -s` would, with `home` as its HOME.
    private func run(_ script: String, home: URL, syntaxOnly: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = syntaxOnly ? ["-n", "-s"] : ["-s"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("The scripts are valid shell, wait for a first login's keychain, and see a missing identity")
    func scripts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sc signing \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let hashes = ["35E94C0D29115DD25A212BCD3F7039311005129F"]
        let install = SigningIdentity.installScript(p12: Data(repeating: 7, count: 200), intermediates: [Data(repeating: 8, count: 100)], passphrase: "a'b c",
                                                    keychainPassword: "p w", hashes: hashes)
        #expect(install.contains("\nP12\n") && install.contains("\nCER\n"), "each heredoc's end is at the start of its line")
        #expect(try run(install, home: home, syntaxOnly: true) == 0)
        #expect(try run(SigningIdentity.checkScript(hashes: hashes), home: home, syntaxOnly: true) == 0)
        #expect(try run(SigningIdentity.checkScript(hashes: hashes), home: home) == 3)
        #expect(try run(install, home: home) == 3)

        // A keychain without the identity: security can't read this one, which is as good as empty.
        let keychains = home.appendingPathComponent("Library/Keychains")
        try FileManager.default.createDirectory(at: keychains, withIntermediateDirectories: true)
        try Data().write(to: keychains.appendingPathComponent("login.keychain-db"))
        #expect(try run(SigningIdentity.checkScript(hashes: hashes), home: home) == 1)
    }
}
