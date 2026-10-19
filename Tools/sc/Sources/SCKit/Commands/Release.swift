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
        runs the unit tests, then builds and zips a Release app. It stops before \
        committing, tagging and pushing, and prints those commands instead — \
        publishing stays a decision you make.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: ArgumentHelp("Use this version instead of the one cog computes.", valueName: "X.Y.Z"))
    var version: String?

    @Flag(name: [.customLong("dry-run"), .customShort("n")], help: "Show what the release would contain; write nothing.")
    var dryRun = false

    @Flag(help: "Version, changelog and notes only; no tests or build.")
    var notesOnly = false

    @Flag(help: "Don't run the unit tests before building.")
    var skipTests = false

    func validate() throws {
        if dryRun && notesOnly { throw ValidationError("--dry-run and --notes-only can't be combined.") }
        if let version, !ProjectVersion.isSemanticVersion(version.hasPrefix("v") ? String(version.dropFirst()) : version) {
            throw ValidationError("'\(version)' isn't a three-part semantic version.")
        }
    }

    func run() async throws {
        let session = try Session.start(global)
        let release = Release(session: session, dryRun: dryRun)
        try await release.run(versionOverride: version.map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 },
                              build: !dryRun && !notesOnly, test: !dryRun && !notesOnly && !skipTests)
    }
}

private struct Release {
    let session: Session
    let dryRun: Bool
    var repo: Repo { session.repo }
    var ui: UI { session.ui }

    func git(_ args: [String]) async throws -> Proc.Collected {
        try await Proc.collect("git", ["-C", repo.root.path] + args)
    }

    var notesFile: URL { repo.releaseDir.appendingPathComponent("RELEASE_NOTES.md") }
    var zip: URL { repo.releaseDir.appendingPathComponent("SecondChance.zip") }

    func run(versionOverride: String?, build: Bool, test: Bool) async throws {
        // A release that stops partway — a failed test or build, or Ctrl-C —
        // would leave the version bump and changelog behind, and the next
        // attempt then refuses to start on the dirty tree. So everything it
        // writes is put back as it was before the error is reported. The zip
        // is only removed: packaging deletes the previous one before writing.
        let restorable = [repo.pbxproj, repo.changelog, notesFile]
        let originals = restorable.map { (url: $0, data: try? Data(contentsOf: $0)) }
        let zipExisted = FileManager.default.fileExists(atPath: zip.path)
        do {
            try await perform(versionOverride: versionOverride, build: build, test: test)
        } catch {
            var undone: [String] = []
            var failed: [String] = []
            for original in originals {
                let current = try? Data(contentsOf: original.url)
                guard current != original.data else { continue }
                do {
                    if let data = original.data {
                        try data.write(to: original.url, options: .atomic)
                    } else {
                        try FileManager.default.removeItem(at: original.url)
                    }
                    undone.append(repo.display(original.url))
                } catch {
                    failed.append("\(repo.display(original.url)): \(error.localizedDescription)")
                }
            }
            if !zipExisted, FileManager.default.fileExists(atPath: zip.path) {
                do {
                    try FileManager.default.removeItem(at: zip)
                    undone.append(repo.display(zip))
                } catch {
                    failed.append("\(repo.display(zip)): \(error.localizedDescription)")
                }
            }
            if !undone.isEmpty {
                ui.line(ui.format("\(.accent("↩︎ Release stopped — put back \(undone.joined(separator: ", "))."))"))
            }
            if !failed.isEmpty {
                ui.warning("Couldn't undo every change the release made — check `git status`.",
                           next: TerminalText(stringLiteral: failed.joined(separator: "\n")))
            }
            throw error
        }
    }

    private func perform(versionOverride: String?, build: Bool, test: Bool) async throws {
        try Proc.require("cog", brew: "cocogitto")
        if build { try Proc.require("xcbeautify", brew: "xcbeautify") }

        // 1. Preflight
        let branch = try await ui.progressStep("Preflight", success: "Preflight checked") { _ in
            try await preflight()
        }

        // 2. Version
        let lastTag = try await git(["describe", "--tags", "--abbrev=0", "--match", "v*"])
        let previous = lastTag.succeeded ? lastTag.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let version = try await resolveVersion(override: versionOverride, previous: previous)
        // CFBundleVersion, kept monotonic off the commit count, which also
        // means it changes every release — WineManager keys its prefix cache
        // on it, so a stale cache can't survive an upgrade.
        let buildNumber = try await git(["rev-list", "--count", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        ui.line(ui.format("\(.primary("🏷  v\(version)"))") + ui.format("\(.muted("  build \(buildNumber), \(versionOverride != nil ? "from --version" : "up from \(previous ?? "no tag")")"))"))

        let range = previous.map { "\($0)..HEAD" } ?? "HEAD"
        let notesResult = try await Proc.collect("cog", ["changelog", range, "--template", repo.notesTemplate.path], cwd: repo.root)
        let notes = Changelog.trimLeadingBlankLines(notesResult.output)
        guard !notes.isEmpty else {
            throw SCError("cog produced empty release notes for \(range).")
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
            ui.line(ui.format("\(.accent("Skipped the build."))"))
            return
        }
        try rewritten.write(to: repo.pbxproj, atomically: true, encoding: .utf8)
        ui.line(ui.format("\(.success("✔︎ MARKETING_VERSION \(oldVersion) → \(version), CURRENT_PROJECT_VERSION → \(buildNumber)"))"))

        // 4. Changelog and notes
        try FileManager.default.createDirectory(at: repo.releaseDir, withIntermediateDirectories: true)
        try (notes + "\n").write(to: notesFile, atomically: true, encoding: .utf8)
        let existing = try? String(contentsOf: repo.changelog, encoding: .utf8)
        let date = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
        if let existing, Changelog.hasSection(for: version, in: existing) {
            // Usually left over from an earlier attempt at this release, so
            // missing whatever has been committed since. Without a terminal
            // to ask, keep it: replacing it would drop any hand edits.
            if ui.confirm("CHANGELOG.md already has a \(version) section. Replace it with the notes generated now?") == true {
                try Changelog.replacing(version: version, date: date, notes: notes, in: existing)
                    .write(to: repo.changelog, atomically: true, encoding: .utf8)
                ui.line(ui.format("\(.success("✔︎ CHANGELOG.md (replaced the \(version) section)"))"))
            } else {
                ui.warning("CHANGELOG.md already has a \(version) section — leaving it alone.")
            }
        } else {
            try Changelog.adding(version: version, date: date, notes: notes, to: existing)
                .write(to: repo.changelog, atomically: true, encoding: .utf8)
            ui.line(ui.format("\(.success("✔︎ CHANGELOG.md"))"))
        }
        ui.line(ui.format("\(.success("✔︎ \(repo.display(notesFile))"))"))

        guard build else {
            ui.line(ui.format("\(.accent("Skipped the tests and build (--notes-only)."))"))
            return
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

        // 7. What's left to do by hand
        let notesPath = repo.display(notesFile)
        ui.success("v\(version) is ready. Review, then publish:", takeaways: [
            "git diff",
            "git add -A && git commit -m \"chore(release): v\(version)\"",
            "git tag -a \"v\(version)\" -m \"v\(version)\"",
            "git push origin \"\(branch)\" \"v\(version)\"",
            "gh release create \"v\(version)\" \"\(repo.display(zip))\" --title \"v\(version)\" --notes-file \"\(notesPath)\"",
        ].map { TerminalText(stringLiteral: $0) })
    }

    /// Returns the current branch.
    private func preflight() async throws -> String {
        guard FileManager.default.fileExists(atPath: repo.pbxproj.path) else { throw SCError("Can't find \(repo.display(repo.pbxproj)).") }
        guard FileManager.default.fileExists(atPath: repo.notesTemplate.path) else { throw SCError("Can't find \(repo.display(repo.notesTemplate)).") }

        // A dirty tree would get swept into the release commit, and the
        // version bump needs to be the only change in it.
        if !dryRun {
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
