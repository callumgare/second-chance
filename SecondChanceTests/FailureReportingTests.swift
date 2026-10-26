import Foundation
import Testing
@testable import SecondChance

@Suite("Report redactor")
struct ReportRedactorTests {
    private let redactor = ReportRedactor(identity: .init(
        homePath: "/Users/nancy",
        userName: "nancy",
        fullName: "Nancy Drew",
        computerNames: ["Nancy's MacBook Pro", "Nancys-MacBook-Pro", "Nancys-MacBook-Pro.local"],
        steamNames: ["sleuth1930", "River Heights Detective"]
    ))

    @Test("The home folder becomes ~, as a path, a file URL and percent-encoded")
    func homeFolder() {
        #expect(redactor.redact("prefix: /Users/nancy/Library/Caches/x") == "prefix: ~/Library/Caches/x")
        #expect(redactor.redact("file:///Users/nancy/Games/a.iso") == "file://~/Games/a.iso")
        let spaced = ReportRedactor(identity: .init(homePath: "/Users/Nancy Drew", userName: "x", fullName: "",
                                                    computerNames: [], steamNames: []))
        #expect(spaced.redact("/Users/Nancy%20Drew/a and /Users/Nancy Drew/b") == "~/a and ~/b")
    }

    @Test("Another account's home keeps that it was a home, not whose; /Users/Shared stays")
    func otherHomes() {
        #expect(redactor.redact("/Users/george/Desktop") == "/Users/<user>/Desktop")
        #expect(redactor.redact("/Users/Shared/Games") == "/Users/Shared/Games")
    }

    @Test("Names go as whole words, whatever their case, and not from inside other words")
    func names() {
        #expect(redactor.redact("Signed in as Nancy Drew (NANCY)") == "Signed in as <user> (<user>)")
        #expect(redactor.redact("Steam account sleuth1930, persona River Heights Detective") ==
                "Steam account <user>, persona <user>")
        #expect(redactor.redact("financy") == "financy")
    }

    @Test("A name too short to be distinctive is left alone")
    func shortNames() {
        let short = ReportRedactor(identity: .init(homePath: "/Users/al", userName: "al", fullName: "",
                                                   computerNames: [], steamNames: []))
        #expect(short.redact("total: al") == "total: al")
        #expect(short.redact("/Users/al/x") == "~/x")
    }

    @Test("The computer's names and Steam IDs are replaced")
    func computerAndSteamID() {
        #expect(redactor.redact("host Nancys-MacBook-Pro.local up") == "host <computer> up")
        #expect(redactor.redact("Nancy's MacBook Pro") == "<computer>")
        #expect(redactor.redact("steamid 76561198012345678.") == "steamid <steam-id>.")
    }

    @Test("Redacting a JSON-like value reaches nested strings")
    func nested() throws {
        let value = redactor.redact(value: ["a": ["/Users/nancy/x", 3], "b": ["c": "nancy"]] as [String: Any])
        let dictionary = try #require(value as? [String: Any])
        let a = try #require(dictionary["a"] as? [Any])
        #expect(a.first as? String == "~/x")
        #expect(a.last as? Int == 3)
        #expect((dictionary["b"] as? [String: Any])?["c"] as? String == "<user>")
    }

    @Test("Steam names are read from loginusers.vdf and the .reg fragment")
    func steamNameParsing() {
        let vdf = """
        "users"
        {
            "76561198012345678"
            {
                "AccountName"        "sleuth1930"
                "PersonaName"        "River Heights Detective"
            }
        }
        """
        #expect(ReportRedactor.values(of: ["AccountName", "PersonaName"], in: vdf) == ["sleuth1930", "River Heights Detective"])
        #expect(ReportRedactor.values(of: ["AutoLoginUser"], in: #""AutoLoginUser"="sleuth1930""#) == ["sleuth1930"])
    }
}

@Suite("Error identifiers")
struct ErrorIdentifierTests {
    enum Sample: Error {
        case plain
        case withPath(String)
    }

    struct Structured: Error {
        let path: String
    }

    @Test("An enum case keeps its name and drops its associated values")
    func enumCases() {
        #expect(ErrorChain.identifier(Sample.plain) == "ErrorIdentifierTests.Sample.plain")
        #expect(ErrorChain.identifier(Sample.withPath("/Users/nancy")) == "ErrorIdentifierTests.Sample.withPath")
    }

    @Test("A struct is its type, with what it's nested in but not its module")
    func structs() {
        #expect(ErrorChain.identifier(Structured(path: "/Users/nancy")) == "ErrorIdentifierTests.Structured")
        #expect(ErrorChain.identifier(WrappBuildError.installIncomplete(reason: "/Users/nancy")) == "WrappBuildError.installIncomplete")
    }

    @Test("An NSError is its domain and code, and its underlying errors are listed")
    func nsErrors() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 13)
        let error = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [
            NSUnderlyingErrorKey: underlying,
            NSFilePathErrorKey: "/Users/nancy/x",
        ])
        #expect(ErrorChain.identifier(error) == "NSCocoaErrorDomain 513")
        #expect(ErrorChain.underlyingIdentifiers(error) == ["NSPOSIXErrorDomain 13"])
    }
}

@Suite("Reporting preferences")
struct ReportingPreferencesTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("reporting-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("With no file, reports are basic and nobody has been asked")
    func defaults() {
        #expect(ReportingPreferences.load(from: temporaryDirectory()) == ReportingPreferences(level: .basic, promptShown: false))
    }

    @Test("What's saved is what's loaded")
    func roundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        ReportingPreferences.update(in: directory) {
            $0.level = .manual
            $0.promptShown = true
        }
        #expect(ReportingPreferences.load(from: directory) == ReportingPreferences(level: .manual, promptShown: true))
    }

    @Test("A file that can't be read gives the defaults")
    func corrupt() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent(ReportingPreferences.fileName))
        #expect(ReportingPreferences.load(from: directory) == ReportingPreferences())
    }

    @Test("A file saved before success reports existed reads as not asked yet")
    func beforeSuccessReports() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{ "level" : "detailed", "promptShown" : true }"#.utf8)
            .write(to: directory.appendingPathComponent(ReportingPreferences.fileName))
        let preferences = ReportingPreferences.load(from: directory)
        #expect(preferences.level == .detailed)
        #expect(preferences.successReports == nil)
    }

    @Test("The success reports answer is saved", arguments: [true, false])
    func successReportsRoundTrip(answer: Bool) {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        ReportingPreferences.update(in: directory) { $0.successReports = answer }
        #expect(ReportingPreferences.load(from: directory).successReports == answer)
    }
}

@Suite("Success reports")
struct SuccessReporterTests {
    @Test("Only a yes, in a run that reports, is counted", arguments: [
        (Bool?.none, true, false),
        (false, true, false),
        (true, false, false),
        (true, true, true),
    ])
    func gating(answer: Bool?, reportingEnabled: Bool, counted: Bool) {
        let preferences = ReportingPreferences(successReports: answer)
        #expect(SuccessReporter.shouldRecord(preferences, reportingEnabled: reportingEnabled) == counted)
    }

    @Test("A metric leaves with which game and how it went, and nothing about whose Mac it was")
    func allowedAttributes() {
        let attributes = [
            "game": "royal-tower", "source": "steam", "engine": "wine", "outcome": "ok",
            "os.version": "15.6", "sentry.release": "second-chance@1.0+1",
            "user.id": "installation", "device.model": "Mac15,3", "memory": "16 GB",
            "translocated": "no", "process": "wrapp",
        ]
        #expect(SuccessReporter.allowed(attributes) == [
            "game": "royal-tower", "source": "steam", "engine": "wine", "outcome": "ok",
            "os.version": "15.6", "sentry.release": "second-chance@1.0+1",
        ])
    }

    @Test("A report's attributes leave out what it doesn't know")
    func reportAttributes() {
        let report = SuccessReport(event: .launch, outcome: "never-started", game: "haunted-carousel",
                                   source: nil, engine: "wine")
        #expect(report.attributes == ["outcome": "never-started", "game": "haunted-carousel", "engine": "wine"])
    }
}

@Suite("Failure reports")
struct FailureReportTests {
    private let redactor = ReportRedactor(identity: .init(homePath: "/Users/nancy", userName: "nancy",
                                                          fullName: "", computerNames: [], steamNames: []))

    @Test("A basic report keeps only the allow-listed context keys, redacted")
    func basicContexts() {
        let contexts: [String: [String: Any]] = [
            "os": ["name": "macOS", "version": "15.6", "locale": "en_AU"],
            "device": ["arch": "arm64", "model": "Mac15,3", "free_storage": 123, "boot_time": "x"],
            "app": ["app_version": "0.4.0", "app_start_time": "x", "device_app_hash": "abc"],
            "culture": ["timezone": "Australia/Melbourne"],
            "failure": ["kind": "X.y", "stage": "/Users/nancy/odd"],
        ]
        let scrubbed = ReportScrubber.contexts(contexts, detail: .basic, redactor: redactor)
        #expect(Set(scrubbed.keys) == ["os", "device", "app", "failure"])
        #expect(Set(scrubbed["os"]?.keys.map { $0 } ?? []) == ["name", "version"])
        #expect(Set(scrubbed["device"]?.keys.map { $0 } ?? []) == ["arch", "model"])
        #expect(Set(scrubbed["app"]?.keys.map { $0 } ?? []) == ["app_version"])
        #expect(scrubbed["failure"]?["stage"] as? String == "~/odd")
    }

    @Test("A detailed report keeps every context, redacted")
    func detailedContexts() {
        let scrubbed = ReportScrubber.contexts(["culture": ["path": "/Users/nancy/x"]], detail: .detailed, redactor: redactor)
        #expect(scrubbed["culture"]?["path"] as? String == "~/x")
    }

    @Test("The fingerprint groups by process, what failed, how and when — not by game")
    func fingerprint() {
        let report = FailureReport(what: "Building the wrapp", kind: "WrappBuildError.installIncomplete",
                                   stage: "Detecting game title...", game: "royal-tower")
        #expect(report.fingerprint(process: "app") ==
                ["app", "Building the wrapp", "WrappBuildError.installIncomplete", "Detecting game title"])
    }

    @Test("A report for an error carries its identifier and its causes, not its message")
    func fromError() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [
            NSLocalizedDescriptionKey: "No file at /Users/nancy/x",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 2),
        ])
        let report = FailureReport(what: "Building the wrapp", error: error)
        #expect(report.kind == "NSCocoaErrorDomain 4")
        #expect(report.tags["caused_by"] == "NSPOSIXErrorDomain 2")
        #expect(!report.title.contains("/Users"))
    }

    @Test("A Wine program's exit code or signal goes in a tag")
    func programExit() {
        let failed = FailureReport(what: "Building the wrapp", error: WineError.executionFailed(exitCode: 126))
        #expect(failed.kind == "WineError.executionFailed")
        #expect(failed.tags["exit_code"] == "126")
        #expect(failed.tags["signal"] == nil)

        let killed = FailureReport(what: "Building the wrapp", error: WineError.terminatedBySignal(SIGKILL))
        #expect(killed.tags["signal"] == SubprocessWatch.signalName(SIGKILL))
        #expect(killed.tags["exit_code"] == nil)

        let other = FailureReport(what: "Building the wrapp", error: WineError.noDisplay)
        #expect(other.tags.isEmpty)
    }
}

@Suite("Failure reporter")
struct FailureReporterGatingTests {
    private let dsn = "https://key@example.invalid/1"

    @Test("A Release build of the app reports")
    func release() {
        #expect(FailureReporter.disabledReason(environment: [:], isDebugBuild: false, dsn: dsn) == nil)
    }

    @Test("Debug, headless, test and WrappPuppeteer runs don't, nor does a build with no DSN",
          arguments: [
              ([:], true, "https://key@example.invalid/1"),
              (["NON_INTERACTIVE": "true"], false, "https://key@example.invalid/1"),
              (["SECOND_CHANCE_PUPPET_DIR": "/tmp/p"], false, "https://key@example.invalid/1"),
              (["XCTestConfigurationFilePath": "/x"], false, "https://key@example.invalid/1"),
              (["SECOND_CHANCE_REPORTING": "0"], false, "https://key@example.invalid/1"),
              ([:], false, ""),
          ] as [([String: String], Bool, String)])
    func disabled(environment: [String: String], debug: Bool, dsn: String) {
        #expect(FailureReporter.disabledReason(environment: environment, isDebugBuild: debug, dsn: dsn) != nil)
    }

    @Test("SECOND_CHANCE_REPORTING=1 turns it on anyway, but not without a DSN")
    func forced() {
        let env = ["SECOND_CHANCE_REPORTING": "1", "NON_INTERACTIVE": "true"]
        #expect(FailureReporter.disabledReason(environment: env, isDebugBuild: true, dsn: dsn) == nil)
        #expect(FailureReporter.disabledReason(environment: env, isDebugBuild: true, dsn: "") != nil)
    }

    @Test("Nobody is asked about a crash in a headless, WrappPuppeteer or test run",
          arguments: [
              (["NON_INTERACTIVE": "true"], false),
              (["SECOND_CHANCE_PUPPET_DIR": "/tmp/p"], false),
              (["XCTestConfigurationFilePath": "/x"], false),
              (["SECOND_CHANCE_REPORTING": "1"], true),
              ([:], true),
          ] as [([String: String], Bool)])
    func canAsk(environment: [String: String], expected: Bool) {
        #expect(FailureReporter.canAsk(environment: environment) == expected)
    }

    @Test("Without asking, a previous crash goes at the setting's detail; Manual drops it")
    func crashDetail() {
        #expect(FailureReporter.defaultCrashDetail(for: .detailed) == .detailed)
        #expect(FailureReporter.defaultCrashDetail(for: .basic) == .basic)
        #expect(FailureReporter.defaultCrashDetail(for: .manual) == nil)
    }
}

@Suite("Report bundle")
struct ReportBundleTests {
    private let redactor = ReportRedactor(identity: .init(homePath: "/Users/nancy", userName: "nancy",
                                                          fullName: "", computerNames: [], steamNames: []))

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Text that barely compresses, so sizes are predictable.
    private func noise(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<(bytes * 3 / 4)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        return data.base64EncodedString()
    }

    @Test("The log and the diagnostics bundle go in redacted")
    func redacts() throws {
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let diagnostics = work.appendingPathComponent("diag", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        try Data("game files in /Users/nancy/Applications\n".utf8).write(to: diagnostics.appendingPathComponent("summary.txt"))

        let out = work.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let zip = try ReportBundle.make(log: "prefix /Users/nancy/Library\n", diagnostics: diagnostics, redactor: redactor, in: out)

        #expect(ReportBundle.size(of: zip) > 0)
        let staging = out.appendingPathComponent("failure-report")
        #expect(try String(contentsOf: staging.appendingPathComponent("log.txt"), encoding: .utf8) == "prefix ~/Library\n")
        #expect(try String(contentsOf: staging.appendingPathComponent("diagnostics/summary.txt"), encoding: .utf8)
                == "game files in ~/Applications\n")
    }

    @Test("Over the cap, the thread samples go first")
    func dropsSamplesFirst() throws {
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let diagnostics = work.appendingPathComponent("diag", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        try Data(noise(bytes: 400_000).utf8).write(to: diagnostics.appendingPathComponent("sample.txt"))
        try Data("summary\n".utf8).write(to: diagnostics.appendingPathComponent("summary.txt"))

        let out = work.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let zip = try ReportBundle.make(log: "short log\n", diagnostics: diagnostics, redactor: redactor,
                                        in: out, sizeCap: 100_000)

        #expect(ReportBundle.size(of: zip) <= 100_000)
        let staging = out.appendingPathComponent("failure-report")
        #expect(ReportBundle.samples(in: staging).isEmpty)
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("diagnostics/summary.txt").path))
        #expect(try String(contentsOf: staging.appendingPathComponent("log.txt"), encoding: .utf8) == "short log\n")
    }

    @Test("Then the log loses its oldest lines, and says so")
    func trimsLog() throws {
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let log = noise(bytes: 1_000_000) + "\nTHE LAST LINE\n"
        let zip = try ReportBundle.make(log: log, diagnostics: nil, redactor: redactor, in: work, sizeCap: 300_000)

        #expect(ReportBundle.size(of: zip) <= 300_000)
        let kept = try String(contentsOf: work.appendingPathComponent("failure-report/log.txt"), encoding: .utf8)
        #expect(kept.hasPrefix("[earlier lines left out to fit the report]"))
        #expect(kept.hasSuffix("THE LAST LINE\n"))
    }

    @Test("A crash report goes in redacted, and screenshots as they are")
    func crashReportAndScreenshots() throws {
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let ips = work.appendingPathComponent("Second Chance-2026-10-22-010500.ips")
        try Data(#"{"procPath":"/Users/nancy/Downloads/Second Chance.app"}"#.utf8).write(to: ips)
        let picture = work.appendingPathComponent("window-1.png")
        let pixels = Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0x00])
        try pixels.write(to: picture)

        let out = work.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = try ReportBundle.make(log: "log\n", diagnostics: nil, crashReport: ips, screenshots: [picture],
                                  redactor: redactor, in: out)

        let staging = out.appendingPathComponent("failure-report")
        #expect(try String(contentsOf: staging.appendingPathComponent(ips.lastPathComponent), encoding: .utf8)
                == #"{"procPath":"~/Downloads/Second Chance.app"}"#)
        #expect(try Data(contentsOf: staging.appendingPathComponent("screenshots/window-1.png")) == pixels)
    }

    @Test("Over the cap, the screenshots go before the log is cut")
    func dropsScreenshotsBeforeLog() throws {
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let picture = work.appendingPathComponent("window-1.png")
        try Data(noise(bytes: 400_000).utf8).write(to: picture)

        let out = work.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let zip = try ReportBundle.make(log: "short log\n", diagnostics: nil, screenshots: [picture],
                                        redactor: redactor, in: out, sizeCap: 100_000)

        #expect(ReportBundle.size(of: zip) <= 100_000)
        let staging = out.appendingPathComponent("failure-report")
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("screenshots").path))
        #expect(try String(contentsOf: staging.appendingPathComponent("log.txt"), encoding: .utf8) == "short log\n")
    }
}

@Suite("Failure report model")
@MainActor
struct FailureReportModelTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString)", isDirectory: true)
    }

    private let report = FailureReport(what: "Running the game", kind: "exit-code", stage: "Starting the game",
                                       game: "royal-tower")

    /// Let the model's own task deliver the outcome.
    private func settle(_ model: FailureReportModel) async {
        for _ in 0..<100 where model.outcome == nil {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("The first failure asks how detailed to send it, holding the way out back until answered")
    func firstFailureAsks() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = FailureReportModel(preferencesDirectory: directory)
        model.track(report, sending: Task { .askingHowDetailed })
        await settle(model)
        #expect(model.outcome == .askingHowDetailed)
        #expect(model.holdsBackWayOut)

        model.choose(.detailed)
        #expect(!model.holdsBackWayOut)
        #expect(ReportingPreferences.load(from: directory) == ReportingPreferences(level: .detailed, promptShown: true))
    }

    @Test("Answering basic makes later reports basic")
    func answersBasic() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = FailureReportModel(preferencesDirectory: directory)
        model.track(report, sending: Task { .askingHowDetailed })
        await settle(model)
        model.choose(.basic)
        #expect(ReportingPreferences.load(from: directory) == ReportingPreferences(level: .basic, promptShown: true))
    }

    @Test("A report that was sent, or is asking whether to be, holds nothing back")
    func otherOutcomesDontHoldBack() async {
        for outcome in [ReportOutcome.sent(eventID: "0123456789abcdef", detail: .basic), .awaitingChoice] {
            let model = FailureReportModel(preferencesDirectory: temporaryDirectory())
            model.track(report, sending: Task { outcome })
            await settle(model)
            #expect(!model.holdsBackWayOut)
        }
    }

    @Test("Declining the Manual choice sends nothing")
    func declines() async {
        let model = FailureReportModel(preferencesDirectory: temporaryDirectory())
        model.track(report, sending: Task { .awaitingChoice })
        await settle(model)
        #expect(model.outcome == .awaitingChoice)
        model.send(nil)
        #expect(model.outcome == .declined)
    }
}

@Suite("Report bundle process list")
struct ReportBundleProcessTests {
    @Test("Only Wine's processes and ours stay in the process list, and the rest are counted")
    func trimsProcesses() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("processes-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("""
              PID  PPID  %CPU %MEM     ELAPSED COMM
              101     1   0.0  0.1    01:00:00 /Applications/Secret Diary.app/Contents/MacOS/Secret Diary
              202     1   1.0  0.5       00:10 /Users/x/Games/Nancy.app/Contents/SharedSupport/wine/bin/wineserver
              203   202   1.0  0.5       00:10 C:\\windows\\system32\\explorer.exe
              204     1   0.0  0.1       00:10 /Users/x/Games/Nancy.app/Contents/MacOS/WrappTemplate
            """.utf8).write(to: file)
        try ReportBundle.onlyRelevantProcesses(in: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("Secret Diary"))
        #expect(text.contains("wineserver") && text.contains("explorer.exe") && text.contains("WrappTemplate"))
        #expect(text.contains("[1 other processes left out]"))
    }
}
