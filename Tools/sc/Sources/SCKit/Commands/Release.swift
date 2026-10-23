import ArgumentParser
import Foundation
import Noora

struct ReleaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Prepare a release: version, changelog, notes, tests and a Release build.",
        discussion: """
        Works out the next version from the conventional commits since the last \
        tag (cocogitto, configured in cog.toml), writes it into the SecondChance \
        and WrappTemplate targets, regenerates CHANGELOG.md and the release notes, \
        runs the unit tests, then builds and zips a Release app, commits and tags \
        it. Pushing and creating the GitHub release are asked first — at the \
        start, if you'd rather it publish once built than wait for you to check \
        the build — so publishing stays a decision you make.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: ArgumentHelp("Use this version instead of the one cog computes.", valueName: "X.Y.Z"))
    var version: String?

    @Flag(name: [.customLong("dry-run"), .customShort("n")], help: "Show what the release would contain; write nothing.")
    var dryRun = false

    @Flag(help: "Version, changelog and notes only; no tests or build.")
    var notesOnly = false

    @Flag(help: ArgumentHelp(
        "Build and package the next version without changing the repo.",
        discussion: "No changelog, notes, commit or tag, and no tests: the version is written into the project for the build and put back afterwards."
    ))
    var buildOnly = false

    @Flag(help: "Don't run the unit tests before building.")
    var skipTests = false

    @Flag(help: ArgumentHelp(
        "Use the notes generated from the commit messages as they are.",
        discussion: "Otherwise Claude Code, when it's installed, rewrites them for players."
    ))
    var plainNotes = false

    @Option(help: ArgumentHelp(
        "The model Claude Code rewrites the notes with.",
        discussion: "An alias such as sonnet or opus, or a full model name. Pass default for Claude Code's own default.",
        valueName: "model"
    ))
    var notesModel = "sonnet"

    @Option(help: ArgumentHelp(
        "How hard Claude Code thinks over the notes: low, medium, high, xhigh or max.",
        discussion: "Most of the rewrite's time is thinking, so this sets how long it takes. Pass default for Claude Code's own.",
        valueName: "level"
    ))
    var notesEffort = "low"

    func validate() throws {
        if dryRun && notesOnly { throw ValidationError("--dry-run and --notes-only can't be combined.") }
        if buildOnly && (dryRun || notesOnly) { throw ValidationError("--build-only can't be combined with --dry-run or --notes-only.") }
        if !["default", "low", "medium", "high", "xhigh", "max"].contains(notesEffort) {
            throw ValidationError("--notes-effort is low, medium, high, xhigh, max or default.")
        }
        if let version, !ProjectVersion.isSemanticVersion(version.hasPrefix("v") ? String(version.dropFirst()) : version) {
            throw ValidationError("'\(version)' isn't a three-part semantic version.")
        }
    }

    func run() async throws {
        let session = try Session.start(global)
        let release = Release(session: session, dryRun: dryRun, buildOnly: buildOnly, plainNotes: plainNotes,
                              notesModel: notesModel == "default" ? nil : notesModel,
                              notesEffort: notesEffort == "default" ? nil : notesEffort)
        try await release.run(versionOverride: version.map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 },
                              build: !dryRun && !notesOnly, test: !dryRun && !notesOnly && !buildOnly && !skipTests)
    }
}

private struct Release {
    let session: Session
    let dryRun: Bool
    /// Build the next version and leave the repo as it was: no changelog,
    /// notes, commit or tag, and the project file put back afterwards.
    let buildOnly: Bool
    /// Skip Claude Code's rewrite of the notes.
    let plainNotes: Bool
    /// `--model` for the rewrite, or nil for Claude Code's default.
    let notesModel: String?
    /// `--effort` for the rewrite, or nil for Claude Code's default.
    let notesEffort: String?
    var repo: Repo { session.repo }
    var ui: UI { session.ui }

    func git(_ args: [String]) async throws -> Proc.Collected {
        try await Proc.collect("git", ["-C", repo.root.path] + args)
    }

    var notesFile: URL { repo.releaseDir.appendingPathComponent("RELEASE_NOTES.md") }
    var zip: URL { repo.releaseDir.appendingPathComponent("SecondChance.zip") }
    /// Sparkle's update feed, published with the zip (docs/updates.md).
    var appcast: URL { repo.releaseDir.appendingPathComponent("appcast.xml") }

    func run(versionOverride: String?, build: Bool, test: Bool) async throws {
        // A release that stops partway — a failed test or build, or Ctrl-C —
        // would leave the version bump and changelog behind, and the next
        // attempt then refuses to start on the dirty tree. So everything it
        // writes is taken back out before the error is reported — only what
        // it wrote: anything else changed in those files, before or during
        // the run, stays. The zip and appcast are only removed: packaging
        // deletes the previous ones before writing.
        let rollback = FileRollback([repo.pbxproj, repo.changelog, notesFile])
        let created = [zip, appcast].filter { !FileManager.default.fileExists(atPath: $0.path) }
        let committed: (version: String, branch: String, publishWhenBuilt: Bool)?
        do {
            committed = try await perform(versionOverride: versionOverride, build: build, test: test, rollback: rollback)
        } catch {
            await restore(rollback, removing: created, reason: "Release stopped")
            throw error
        }
        if buildOnly {
            // The build has the version baked in; the repo goes back as it was.
            await restore(rollback, removing: [], reason: "Build only")
            if let committed {
                ui.success("Built v\(committed.version) — not committed or tagged.", takeaways: [TerminalText(stringLiteral: repo.display(zip))])
            }
            return
        }
        // Outside the rollback: once committed, the files are the commit's,
        // and a failed push mustn't put the old ones back over it.
        if let committed {
            try await publish(version: committed.version, branch: committed.branch, ask: !committed.publishWhenBuilt)
        }
    }

    /// Run the linters. On a failure, ask whether to release anyway, defaulting
    /// to no; a dry run only reports it, and a run that can't ask stops.
    private func checkLint() async throws {
        let failed = await Lint.run(session: session)
        guard !failed.isEmpty else { return }
        ui.warning("Lint failed: \(failed.joined(separator: ", ")).", next: "Fix it and run ./sc lint, or release anyway.")
        if dryRun { return }
        guard try ui.confirm("Continue the release with lint failures?", default: false) == true else {
            throw SCError("Release stopped: lint failed (\(failed.joined(separator: ", "))).",
                          hints: ["./sc lint shows the problems; swiftlint --fix fixes many Swift ones."])
        }
    }

    /// Take the release's writes back out of the files, and remove the
    /// packaged files in `removing` — the ones it created.
    private func restore(_ rollback: FileRollback, removing: [URL], reason: String) async {
        let outcome = await rollback.restore()
        var undone = outcome.undone.map(repo.display)
        var failed = outcome.failed.map { "\(repo.display($0.url)): \($0.reason)" }
        for file in removing where FileManager.default.fileExists(atPath: file.path) {
            do {
                try FileManager.default.removeItem(at: file)
                undone.append(repo.display(file))
            } catch {
                failed.append("\(repo.display(file)): \(error.localizedDescription)")
            }
        }
        if !undone.isEmpty {
            ui.line(ui.format("\(.accent("↩︎ \(reason) — put back \(undone.joined(separator: ", "))."))"))
        }
        if !failed.isEmpty {
            ui.warning("Couldn't undo every change the release made — check `git status`.",
                       next: TerminalText(stringLiteral: failed.joined(separator: "\n")))
        }
    }

    /// Returns the release's version and branch, and whether to publish
    /// without asking again, once it's committed and tagged (for
    /// --build-only, once it's packaged), or nil when it stopped short of
    /// that (a dry run, --notes-only).
    private func perform(
        versionOverride: String?, build: Bool, test: Bool, rollback: FileRollback
    ) async throws -> (version: String, branch: String, publishWhenBuilt: Bool)? {
        try Proc.require("cog", brew: "cocogitto")
        if build { try Proc.require("xcbeautify", brew: "xcbeautify") }

        // 1. Preflight
        let branch = try await ui.progressStep("Preflight", success: "Preflight checked") { _ in
            try await preflight()
        }

        // Lint, before anything is generated: a release can go out with lint
        // failures, but only when someone says so.
        try await checkLint()

        // Asked now, while someone is here to answer: the tests, build and
        // symbols upload take long enough that they may have walked away,
        // and a release left waiting at the publish prompt is half done.
        let publishWhenBuilt = try build && !dryRun && !buildOnly
            && ui.confirm("Once it's built, push it and create the GitHub release straight away, without waiting for you to check the build?") == true

        // 2. Version
        let lastTag = try await git(["describe", "--tags", "--abbrev=0", "--match", "v*"])
        let previous = lastTag.succeeded ? lastTag.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let version = try await resolveVersion(override: versionOverride, previous: previous)
        // CFBundleVersion, kept monotonic off the commit count, which also
        // means it changes every release — WineManager keys its prefix cache
        // on it, so a stale cache can't survive an upgrade.
        let buildNumber = try await git(["rev-list", "--count", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = versionOverride != nil ? "from --version" : "up from \(previous ?? "no tag")"
        ui.line(ui.format("\(.primary("🏷  v\(version)"))") + ui.format("\(.muted("  build \(buildNumber), \(origin)"))"))

        var notes: String
        if buildOnly {
            notes = ""
        } else {
            let range = previous.map { "\($0)..HEAD" } ?? "HEAD"
            let notesResult = try await Proc.collect("cog", ["changelog", range, "--template", repo.notesTemplate.path], cwd: repo.root)
            notes = Changelog.trimLeadingBlankLines(notesResult.output)
            guard !notes.isEmpty else {
                throw SCError("cog produced empty release notes for \(range).")
            }
            notes = await readableNotes(notes, range: range)
        }

        // 3. Project version
        let pbxproj = try String(contentsOf: repo.pbxproj, encoding: .utf8)
        let rewritten = try ProjectVersion.rewrite(pbxproj, version: version, build: buildNumber)
        let oldVersion = ProjectVersion.current(in: pbxproj) ?? "?"
        if dryRun {
            ui.line(ui.format("\(.accent("🔎 Dry run — would set MARKETING_VERSION \(oldVersion) → \(version) in \(ProjectVersion.versionedTargets.joined(separator: ", ")):"))"))
            ui.line(try await diff(pbxproj, rewritten).split(separator: "\n").map { "   " + $0 }.joined(separator: "\n"))
            ui.line(ui.format("\(.accent("🔎 Dry run — release notes would read:"))"))
            ui.line(notes.split(separator: "\n", omittingEmptySubsequences: false).map { "   " + $0 }.joined(separator: "\n"))
            ui.line(ui.format("\(.accent("Skipped the build — a release would also upload its debug symbols to Sentry."))"))
            return nil
        }
        try await rollback.write(rewritten, to: repo.pbxproj)
        ui.line(ui.format("\(.success("✔︎ MARKETING_VERSION \(oldVersion) → \(version), CURRENT_PROJECT_VERSION → \(buildNumber)"))"))

        // 4. Changelog and notes
        try FileManager.default.createDirectory(at: repo.releaseDir, withIntermediateDirectories: true)
        if !buildOnly {
            let existing = try? String(contentsOf: repo.changelog, encoding: .utf8)
            let date = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
            if let existing, Changelog.hasSection(for: version, in: existing) {
                // Usually left over from an earlier attempt at this release, so
                // missing whatever has been committed since. Without a terminal
                // to ask, keep it: replacing it would drop any hand edits.
                if try ui.confirm("CHANGELOG.md already has a \(version) section. Replace it with the notes generated now?") == true {
                    try await rollback.write(Changelog.replacing(version: version, date: date, notes: notes, in: existing),
                                             to: repo.changelog)
                    ui.line(ui.format("\(.success("✔︎ CHANGELOG.md (replaced the \(version) section)"))"))
                } else {
                    ui.warning("CHANGELOG.md already has a \(version) section — leaving it alone.")
                }
            } else {
                try await rollback.write(Changelog.adding(version: version, date: date, notes: notes, to: existing),
                                         to: repo.changelog)
                ui.line(ui.format("\(.success("✔︎ CHANGELOG.md"))"))
            }
            // CHANGELOG.md is where the notes are edited, as it's the copy
            // that's committed; everything else is made from its section.
            notes = try reviewNotes(version: version)
            try await rollback.write(notes + "\n", to: notesFile)
            ui.line(ui.format("\(.success("✔︎ \(repo.display(notesFile))"))"))
        }

        guard build else {
            ui.line(ui.format("\(.accent("Skipped the tests and build (--notes-only)."))"))
            return nil
        }

        // 5. Tests
        if test {
            let runner = TestRunner(session: session)
            // Not ensureTestBuild(AppBuildOptions()): an option group built
            // with init() rather than parsed has no values, and reading one traps.
            try await runner.xcode.buildForTesting()
            let unit = try await runner.unit(stamp: UI.timestamp())
            guard unit.status == 0 else {
                throw SCError("Unit tests failed — not building a release from this.", exitCode: unit.status)
            }
        }

        // 6. Build and package
        try await Xcode(session: session).buildApp(configuration: "Release")
        let app = repo.releaseProducts.appendingPathComponent("Second Chance.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw SCError("The build reported success but \(repo.display(app)) is missing.")
        }
        try checkSentryDSN(in: app)
        try await ui.progressStep("Package", success: "Packaged \(repo.display(zip))") { _ in
            try? FileManager.default.removeItem(at: zip)
            // ditto, not zip: the Wine and ScummVM payloads inside
            // WrappTemplate.app are full of symlinks and extended attributes
            // that `zip` would flatten.
            let result = try await Proc.collect("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
            guard result.succeeded else { throw SCError("ditto failed: \(result.error)") }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        } ?? "?"
        let archs = (try? await Proc.collect("/usr/bin/lipo", ["-archs", app.appendingPathComponent("Contents/MacOS/Second Chance").path]))?
            .output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let sha = (try? await Proc.collect("/usr/bin/shasum", ["-a", "256", zip.path]))?
            .output.split(separator: " ").first.map(String.init) ?? "?"
        await ui.table(headers: ["", ""], rows: [
            ["Version", "v\(version)"], ["Build", buildNumber], ["Zip", repo.display(zip)],
            ["Size", size], ["Architectures", archs], ["sha256", sha],
        ])

        // The app is signed with an Apple Development certificate, not a
        // Developer ID one, so it can't be notarized: on macOS 15+ users have
        // to approve it in System Settings → Privacy & Security.
        let signature = try await Proc.collect("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
        if !(signature.output + signature.error).contains("Authority=Developer ID") {
            ui.warning("Not signed with Developer ID, so not notarized — first launch needs approval in System Settings → Privacy & Security.")
        }

        if buildOnly { return (version, branch, false) }

        // 7. Debug symbols, so crash reports from this version can be read.
        try await uploadDebugSymbols()

        // 8. The update feed. Sparkle in the installed apps reads it from the
        // latest GitHub release and only installs what this key signed.
        try await writeAppcast(app: app, version: version, notes: ReleaseNotes.forUpdateWindow(notes))

        // 9. Commit and tag locally — still undoable, so the rollback covers
        // them too. Pushing is what other people see, so `run` asks first.
        try await commitAndTag(version: version)
        return (version, branch, publishWhenBuilt)
    }

    /// The notes rewritten by Claude Code for players, or cog's notes as they
    /// are with `--plain-notes`, without Claude Code, or when the rewrite
    /// fails — a release never stops for want of nicer notes.
    private func readableNotes(_ notes: String, range: String) async -> String {
        if plainNotes { return notes }
        guard Proc.which("claude") != nil else {
            ui.detail("Claude Code isn't installed, so the notes are the commit messages as they are.")
            return notes
        }
        let title = "Rewrite the notes with Claude Code"
        let logFile = try? ui.makeLogFile("release-notes")
        let handle = logFile.flatMap { try? FileHandle(forWritingTo: $0) }
        defer { try? handle?.close() }
        let rewritten: String? = try? await ui.progressStep(title, success: "Rewrote the notes for players") { update in
            let prompt = try String(contentsOf: repo.notesPrompt, encoding: .utf8)
            // Whole messages: the bodies say what each change was for, which
            // the summaries in the notes leave out.
            let log = try await git(["log", "--no-merges", "--format=commit %h%n%B", range])
            guard log.succeeded else { throw SCError("git log failed: \(log.error)") }
            // The spinner says what Claude Code is doing and for how long,
            // redrawn each second so the time moves between its steps.
            let status = StepStatus(title: title, update: update)
            let ticking = Task {
                while !Task.isCancelled {
                    status.redraw()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            defer { ticking.cancel() }
            let rewrite = try await ReleaseNotes.rewrite(
                notes: notes, commits: log.output, prompt: prompt, model: notesModel, effort: notesEffort, cwd: repo.root,
                log: LogSink(file: handle), activity: { status.set($0) }
            )
            return ReleaseNotes.markdown(rewrite)
        }
        if let logFile { ui.detail("Claude Code's session: \(repo.display(logFile))") }
        guard let rewritten else {
            ui.warning("Using the notes from the commit messages as they are.",
                       next: "Check Claude Code works with `claude -p hello`, or pass --plain-notes.")
            return notes
        }
        return rewritten
    }

    /// Pause so the version's CHANGELOG.md section can be edited before
    /// anything else uses it, then read back whatever it now says. With no
    /// terminal to ask, the notes are used as written.
    private func reviewNotes(version: String) throws -> String {
        let section = { () throws -> String in
            let text = try String(contentsOf: repo.changelog, encoding: .utf8)
            guard let notes = Changelog.section(for: version, in: text), !notes.isEmpty else {
                throw SCError("CHANGELOG.md has no notes under its \(version) heading.")
            }
            return notes
        }
        let editHint = "📝 The release notes are the \(version) section of CHANGELOG.md. Edit them there now if you want to"
            + " — the GitHub release and the update window use that section once you continue."
        ui.line(ui.format("\(.accent(editHint))"))
        ui.line(try section().split(separator: "\n", omittingEmptySubsequences: false).map { "   " + $0 }.joined(separator: "\n"))
        if try ui.confirm("Done with the notes? Continue the release with CHANGELOG.md's \(version) section as it is now?", default: true) == false {
            throw SCError("Stopped at the release notes.", hints: ["Run sc release again when you're ready."])
        }
        return try section()
    }

    /// A release built without `SENTRY_DSN` in `.env` would send no failure
    /// reports, and nothing would say so. Stops the release; a `--build-only`
    /// build, for trying out, only warns.
    private func checkSentryDSN(in app: URL) throws {
        let plists = [
            app.appendingPathComponent("Contents/Info.plist"),
            app.appendingPathComponent("Contents/Resources/WrappTemplate.app/Contents/Info.plist"),
        ]
        let missing = plists.filter { plist in
            let dsn = NSDictionary(contentsOf: plist)?["SentryDSN"] as? String ?? ""
            return dsn.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !missing.isEmpty else { return }
        let message = "The build has no Sentry DSN, so it would send no failure reports."
        let hint = "Set SENTRY_DSN in .env (see .env.example) and build again."
        if buildOnly {
            ui.warning("\(message) \(hint)")
        } else {
            throw SCError(message, hints: [hint] + missing.map { "No SentryDSN in \(repo.display($0))" })
        }
    }

    /// Upload the Release build's debug symbols to Sentry, and keep a zip of
    /// them beside the release. A crash report from this version is
    /// unreadable without them, and the next build overwrites them, so a
    /// failure stops the release here, before anything is published.
    private func uploadDebugSymbols() async throws {
        let symbols = ["Second Chance.app.dSYM", "WrappTemplate.app.dSYM"].map { repo.releaseProducts.appendingPathComponent($0) }
        for dSYM in symbols where !FileManager.default.fileExists(atPath: dSYM.path) {
            throw SCError("The Release build left no \(repo.display(dSYM)).")
        }
        guard let sentryCLI = Proc.which("sentry-cli") else {
            throw SCError("sentry-cli isn't installed, and the release's debug symbols need uploading.",
                          hints: ["brew install getsentry/tools/sentry-cli"])
        }
        let settings = DotEnv.load(repo)
        guard let org = settings["SENTRY_ORG"], !org.isEmpty,
              let project = settings["SENTRY_PROJECT"], !project.isEmpty else {
            throw SCError(".env doesn't name the Sentry organisation and project to upload debug symbols to.",
                          hints: ["Set SENTRY_ORG and SENTRY_PROJECT in .env (see .env.example)."])
        }
        let lookup = try await Proc.collect("/usr/bin/security", ["find-generic-password", "-s", "sentry-auth-token", "-w"])
        let token = lookup.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lookup.succeeded, !token.isEmpty else {
            throw SCError("There's no Sentry auth token in the login keychain.",
                          hints: ["security add-generic-password -s sentry-auth-token -a \"$USER\" -w <token> (docs/releasing.md)"])
        }

        let archive = repo.releaseDir.appendingPathComponent("dSYMs.zip")
        try await ui.progressStep("Debug symbols", success: "Uploaded the debug symbols to Sentry, and kept \(repo.display(archive))") { _ in
            try? FileManager.default.removeItem(at: archive)
            let staging = repo.releaseDir.appendingPathComponent("dSYMs")
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            for dSYM in symbols {
                try FileManager.default.copyItem(at: dSYM, to: staging.appendingPathComponent(dSYM.lastPathComponent))
            }
            let zipped = try await Proc.collect("/usr/bin/ditto", ["-c", "-k", "--keepParent", staging.path, archive.path])
            guard zipped.succeeded else { throw SCError("ditto failed: \(zipped.error)") }

            // Everything sentry-cli needs is passed in, so it reads no .env
            // or .sentryclirc of its own.
            let upload = try await Proc.collect(sentryCLI, ["debug-files", "upload", "--wait", staging.path], env: [
                "SENTRY_AUTH_TOKEN": token, "SENTRY_ORG": org, "SENTRY_PROJECT": project, "SENTRY_LOAD_DOTENV": "0",
            ], cwd: repo.root)
            guard upload.succeeded else {
                throw SCError("sentry-cli couldn't upload the debug symbols.", hints: [upload.output + upload.error])
            }
        }
    }

    /// Sign the zip with the Sparkle key in the login keychain and write
    /// `appcast.xml` for it, with the release notes embedded. Stops if the
    /// key isn't the one the app checks updates against: the release would
    /// publish, and every installed copy would then refuse it.
    private func writeAppcast(app: URL, version: String, notes: String) async throws {
        let generateKeys = repo.sparkleTools.appendingPathComponent("generate_keys")
        let generateAppcast = repo.sparkleTools.appendingPathComponent("generate_appcast")
        guard FileManager.default.isExecutableFile(atPath: generateAppcast.path) else {
            throw SCError("Can't find Sparkle's tools in \(repo.display(repo.sparkleTools)).",
                          hints: ["The build downloads them with the Sparkle package — check it resolved."])
        }
        let infoPlist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoPlist),
              let appKey = info["SUPublicEDKey"] as? String,
              let feed = info["SUFeedURL"] as? String,
              let feedRange = feed.range(of: "/releases/latest/download/") else {
            throw SCError("\(repo.display(infoPlist)) has no SUPublicEDKey, or no SUFeedURL pointing at a GitHub release.")
        }
        let repoURL = String(feed[..<feedRange.lowerBound])

        try await ui.progressStep("Update feed", success: "Signed the update and wrote \(repo.display(appcast))") { _ in
            let lookup = try await Proc.collect(generateKeys.path, ["-p"])
            let keychainKey = lookup.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard lookup.succeeded, !keychainKey.isEmpty else {
                throw SCError("There's no Sparkle signing key in the login keychain.",
                              hints: ["Import it with `\(repo.display(generateKeys)) -f <exported key file>` (docs/updates.md)."])
            }
            guard keychainKey == appKey else {
                throw SCError("The keychain's Sparkle key isn't the one in SecondChance/Info.plist.",
                              hints: ["Keychain: \(keychainKey)", "Info.plist: \(appKey)",
                                      "Installed copies would reject an update signed with it (docs/updates.md)."])
            }

            // generate_appcast reads every archive in a directory, finds the
            // notes by the archive's name and moves things it considers old
            // aside — so it gets a directory of its own each time.
            let staging = repo.releaseDir.appendingPathComponent("appcast-staging")
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.linkItem(at: zip, to: staging.appendingPathComponent(zip.lastPathComponent))
            try (notes + "\n").write(to: staging.appendingPathComponent("SecondChance.md"), atomically: true, encoding: .utf8)

            try? FileManager.default.removeItem(at: appcast)
            let result = try await Proc.collect(generateAppcast.path, [
                "--embed-release-notes",
                "--download-url-prefix", "\(repoURL)/releases/download/v\(version)/",
                "--full-release-notes-url", "\(repoURL)/releases",
                "--link", repoURL,
                "-o", appcast.path,
                staging.path,
            ])
            guard result.succeeded, FileManager.default.fileExists(atPath: appcast.path) else {
                throw SCError("generate_appcast failed.", hints: [result.output + result.error])
            }
        }
    }

    /// The release commit and its tag. If either fails, whatever was done is
    /// taken back out of git, leaving the files for `run`'s rollback.
    private func commitAndTag(version: String) async throws {
        let tag = "v\(version)"
        let files = [repo.pbxproj.path, repo.changelog.path]
        try await ui.progressStep("Commit and tag", success: "Committed and tagged \(tag)") { _ in
            let add = try await git(["add", "--"] + files)
            guard add.succeeded else { throw SCError("git add failed: \(add.error)") }
            let commit = try await git(["commit", "-m", "chore(release): \(tag)", "--"] + files)
            guard commit.succeeded else {
                _ = try? await git(["reset", "-q", "--"] + files)
                throw SCError("git commit failed.", hints: [commit.output + commit.error])
            }
            let tagged = try await git(["tag", "-a", tag, "-m", tag])
            guard tagged.succeeded else {
                // Mixed reset: the commit goes, its changes stay in the tree
                // for the rollback to put back.
                _ = try? await git(["reset", "-q", "HEAD~1"])
                throw SCError("git tag failed: \(tagged.error)")
            }
        }
    }

    /// Push the branch and tag and create the GitHub release, if the user said
    /// so at the start or says so now (`ask`). Otherwise — or with no
    /// terminal to ask — print the commands. A
    /// failure here leaves the commit and tag alone: they're correct, and
    /// whatever didn't happen can be run by hand.
    private func publish(version: String, branch: String, ask: Bool) async throws {
        let tag = "v\(version)"
        let push = ["git", "push", "origin", branch, tag]
        let release = ["gh", "release", "create", tag, repo.display(zip), repo.display(appcast), "--title", tag, "--notes-file", repo.display(notesFile)]
        let pushLine = push.map(Self.shellQuoted).joined(separator: " ")
        let releaseLine = release.map(Self.shellQuoted).joined(separator: " ")

        guard try !ask || ui.confirm("Push \(branch) and \(tag) to origin, and create the GitHub release?") == true else {
            ui.success("\(tag) is committed and tagged locally. To publish:", takeaways: [TerminalText(stringLiteral: pushLine), TerminalText(stringLiteral: releaseLine)])
            return
        }
        let pushed = try await ui.progressStep("Push", success: "Pushed \(branch) and \(tag)") { _ in
            try await git(["push", "origin", branch, tag])
        }
        guard pushed.succeeded else {
            throw SCError("git push failed — \(tag) is still committed and tagged locally.",
                          hints: [pushed.error, "Then run: \(pushLine) && \(releaseLine)"])
        }
        try Proc.require("gh", brew: "gh")
        let created = try await ui.progressStep("GitHub release", success: "Created the \(tag) release") { _ in
            try await Proc.collect("gh", Array(release.dropFirst()), cwd: repo.root)
        }
        guard created.succeeded else {
            throw SCError("gh release create failed — \(tag) is pushed.", hints: [created.error, "Then run: \(releaseLine)"])
        }
        ui.success("\(tag) is released.", takeaways: [TerminalText(stringLiteral: created.output.trimmingCharacters(in: .whitespacesAndNewlines))])
    }

    private static func shellQuoted(_ word: String) -> String {
        word.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=@".contains($0) } ? word : "\"\(word)\""
    }

    /// Returns the current branch.
    private func preflight() async throws -> String {
        guard FileManager.default.fileExists(atPath: repo.pbxproj.path) else { throw SCError("Can't find \(repo.display(repo.pbxproj)).") }
        guard FileManager.default.fileExists(atPath: repo.notesTemplate.path) else { throw SCError("Can't find \(repo.display(repo.notesTemplate)).") }

        // A dirty tree would get swept into the release commit, and the
        // version bump needs to be the only change in it. A build-only run
        // commits nothing and puts the project file back byte for byte, so
        // uncommitted work is safe — and gets built.
        if !dryRun && !buildOnly {
            let status = try await git(["status", "--porcelain"])
            if !status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw SCError("The working tree isn't clean.", hints: ["Commit or stash first (or use --dry-run).", status.output])
            }
        }

        var warnings: [(message: TerminalText, next: TerminalText?)] = []
        defer { ui.warnings(warnings) }

        let branch = try await git(["rev-parse", "--abbrev-ref", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch != "main" { warnings.append(("On branch '\(branch)', not main.", nil)) }

        let hookPath = try await git(["rev-parse", "--git-path", "hooks/commit-msg"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let hook = hookPath.hasPrefix("/") ? hookPath : repo.root.appendingPathComponent(hookPath).path
        if !FileManager.default.isExecutableFile(atPath: hook) {
            warnings.append(("cog's commit-msg hook isn't installed here.", "Run `sc setup` to lint messages as you commit."))
        }

        // A message cog can't parse silently vanishes from the changelog —
        // worth knowing, but pushed history can't always be rewritten, so
        // it's a warning rather than a stop.
        let lint = try await Proc.collect("cog", ["check"], cwd: repo.root)
        if !lint.succeeded {
            let bad = (lint.output + lint.error).split(separator: "\n").filter { $0.contains("Commit message:") }
            warnings.append(("Some commits since the last tag aren't valid conventional commits; they'll be missing from the release notes.",
                             TerminalText(stringLiteral: bad.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))))
        }
        return branch
    }

    private func resolveVersion(override: String?, previous: String?) async throws -> String {
        let version: String
        if let override {
            version = override
        } else {
            // cog prints the version on stdout and nothing else when it has
            // one to give. When no commit warrants a bump it prints an
            // explanation instead and still exits 0, so the output is checked
            // rather than the status.
            let bumped = try await Proc.collect("cog", ["bump", "--auto", "--dry-run", "--skip-untracked"], cwd: repo.root)
            let last = bumped.output.split(separator: "\n").last.map(String.init) ?? ""
            let candidate = last.hasPrefix("v") ? String(last.dropFirst()) : last
            guard ProjectVersion.isSemanticVersion(candidate) else {
                throw SCError(
                    "No releasable commits since \(previous ?? "the start").",
                    hints: ["Only feat, fix and breaking changes bump the version — use --version to force a release anyway."]
                )
            }
            version = candidate
        }
        guard ProjectVersion.isSemanticVersion(version) else { throw SCError("'\(version)' isn't a three-part semantic version.") }
        if try await git(["rev-parse", "-q", "--verify", "refs/tags/v\(version)"]).succeeded {
            throw SCError("Tag v\(version) already exists.")
        }
        return version
    }

    private func diff(_ old: String, _ new: String) async throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try old.write(to: a, atomically: true, encoding: .utf8)
        try new.write(to: b, atomically: true, encoding: .utf8)
        let result = try await Proc.collect("/usr/bin/diff", ["-u", a.path, b.path])
        // Drop the two file-name header lines.
        return result.output.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(2).joined(separator: "\n")
    }
}

/// A progress step's message while Claude Code works: the step, what it's
/// doing now, and how long the step has taken.
private final class StepStatus: @unchecked Sendable {
    private let lock = NSLock()
    private let title: String
    private let update: @Sendable (String) -> Void
    private let started = Date()
    private var doing = "Starting"

    init(title: String, update: @escaping @Sendable (String) -> Void) {
        self.title = title
        self.update = update
    }

    func set(_ activity: String) {
        lock.withLock { doing = activity }
        redraw()
    }

    func redraw() {
        let seconds = Int(Date().timeIntervalSince(started))
        let elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m\(String(format: "%02d", seconds % 60))s"
        update("\(title) — \(lock.withLock { doing }) (\(elapsed))")
    }
}
