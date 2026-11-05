import Foundation

/// Extra checkouts of this repo (`git worktree`), and what makes one ready to
/// work in: what it should share with the main checkout, and what it can
/// start from a clone of. docs/dev-cli.md#worktrees.
enum Worktrees {
    /// Where `sc worktree add` makes them: inside the main checkout, under
    /// `.claude` (ignored), where Claude Code makes its own, so both kinds
    /// are found, synced (left out of `--on`'s sync) and removed alike.
    static let directory = ".claude/worktrees"

    /// Ignored files a worktree reads from the main checkout's, as links:
    /// one copy, so a note written in a worktree is there in every other,
    /// and none goes stale. `.env` is this Mac's settings; `.claude`'s are
    /// agents and skills kept out of the repo.
    static let linked = [".local", ".env", ".claude/agents", ".claude/skills"]

    /// Parts of `DerivedData` cloned from the main checkout's. Neither
    /// depends on where the checkout is: the packages Xcode resolved (their
    /// recorded paths rewritten), and the module cache, whose entries are
    /// keyed by hash and checked against their inputs before they're used.
    /// `Build` isn't: it records the checkout's path throughout, so it is
    /// rebuilt in full and a clone would only pin old blocks.
    static let clonedDerivedData = ["SourcePackages", "ModuleCache.noindex"]

    /// Parts of a SwiftPM package's `.build` cloned from the main
    /// checkout's: its dependencies, fetched and unpacked (Sentry's are
    /// gigabytes), and the state that records them. Not what it compiled.
    static let clonedPackageState = ["checkouts", "repositories", "artifacts", "workspace-state.json"]

    /// Written to each package in a worktree: SourceKit-LSP indexes in the
    /// background unless the workspace says not to, gigabytes in each
    /// package's `.build/index-build`. A workspace's file outranks what the
    /// editor asks for, and a package's own is the one that counts.
    static let sourceKitConfig = "{\n    \"backgroundIndexing\": false\n}\n"
    static let sourceKitConfigPath = ".sourcekit-lsp/config.json"
    static let sourceKitExclude = ".sourcekit-lsp/"

    /// Set while `sc worktree add` runs git, so the post-checkout hook
    /// leaves the preparing to it.
    static let preparingVariable = "SC_WORKTREE_PREPARING"

    /// The first line of the hook `sc setup` installs, by which it knows
    /// its own.
    static let hookMarker = "# Installed by sc setup: prepares a new worktree"

    /// The `post-checkout` hook. git runs it with a null old HEAD for a new
    /// worktree (Claude Code's too), and it runs the main checkout's sc to
    /// prepare it. A hook's failure would fail the `git worktree add` that
    /// made the worktree, so it never fails: it says what to run instead.
    static let hookScript = """
    #!/bin/sh
    \(hookMarker)
    # (sc worktree prepare). See docs/dev-cli.md#worktrees.
    case "$1" in *[!0]*) exit 0 ;; esac
    [ -n "$\(preparingVariable)" ] && exit 0
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
    common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
    main="$(dirname "$common")"
    [ "$top" = "$main" ] && exit 0
    [ -x "$main/sc" ] || exit 0
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    "$main/sc" worktree prepare "$top" ||
        echo "sc: preparing $top didn't finish; run ./sc worktree prepare there." >&2
    exit 0

    """

    struct Report {
        var linked: [String] = []
        var cloned: [String] = []
        var configured = 0
        var excluded = false
        var notes: [String] = []
    }

    /// The main checkout of the repo `dir` is in (itself, when it is).
    static func mainCheckout(of dir: URL) async throws -> URL {
        let common = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: dir)
        return URL(fileURLWithPath: common, isDirectory: true).deletingLastPathComponent().standardizedFileURL
    }

    static func topLevel(of dir: URL) async throws -> URL {
        URL(fileURLWithPath: try await git(["rev-parse", "--show-toplevel"], in: dir), isDirectory: true).standardizedFileURL
    }

    static func git(_ args: [String], in dir: URL) async throws -> String {
        let result = try await Proc.collect("git", ["-C", dir.path] + args)
        guard result.succeeded else {
            throw SCError("git \(args.joined(separator: " ")) failed in \(dir.path): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The directories holding a SwiftPM package, relative to the checkout.
    static func packageDirectories(in worktree: URL) async throws -> [String] {
        try await git(["ls-files", "--", "Package.swift", "*/Package.swift"], in: worktree)
            .split(separator: "\n")
            .map { ($0 as NSString).deletingLastPathComponent }
    }

    /// Links, clones and SourceKit-LSP settings, each only where the
    /// worktree hasn't one of its own, so it is safe to run again.
    static func prepare(_ worktree: URL, main: URL, packages: [String]) -> Report {
        var report = Report()
        let files = FileManager.default

        for name in linked {
            let source = main.appendingPathComponent(name)
            let link = worktree.appendingPathComponent(name)
            guard exists(source) else { continue }
            if (try? files.destinationOfSymbolicLink(atPath: link.path)) != nil { continue }
            if exists(link) {
                // What `git worktree add` leaves of an ignored folder that
                // some tool made empty is no copy of its own.
                let contents = (try? files.contentsOfDirectory(atPath: link.path)) ?? ["?"]
                guard isDirectory(link), contents.isEmpty, (try? files.removeItem(at: link)) != nil else {
                    report.notes.append("\(name) has its own copy here, so it isn't linked to the main checkout's.")
                    continue
                }
            }
            do {
                try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.createSymbolicLink(at: link, withDestinationURL: source)
                report.linked.append(name)
            } catch {
                report.notes.append("Couldn't link \(name): \(error.localizedDescription)")
            }
        }

        for name in clonedDerivedData {
            let relative = "DerivedData/\(name)"
            let source = main.appendingPathComponent(relative)
            let target = worktree.appendingPathComponent(relative)
            guard exists(source), !exists(target) else { continue }
            if let failure = clone(source, to: target) {
                report.notes.append("\(relative) wasn't cloned (\(failure)); the first build fetches or makes it.")
                continue
            }
            if name == "SourcePackages" { rewritePaths(in: target, from: main, to: worktree) }
            report.cloned.append(relative)
        }

        for package in packages {
            let build = package.isEmpty ? ".build" : "\(package)/.build"
            let source = main.appendingPathComponent(build)
            let target = worktree.appendingPathComponent(build)
            guard exists(source.appendingPathComponent("workspace-state.json")), !exists(target) else { continue }
            do {
                try files.createDirectory(at: target, withIntermediateDirectories: true)
            } catch {
                report.notes.append("Couldn't make \(build): \(error.localizedDescription)")
                continue
            }
            var failures: [String] = []
            for part in clonedPackageState where exists(source.appendingPathComponent(part)) {
                if let failure = clone(source.appendingPathComponent(part), to: target.appendingPathComponent(part)) {
                    failures.append("\(part): \(failure)")
                }
            }
            if failures.isEmpty {
                rewritePaths(in: target, from: main, to: worktree)
                report.cloned.append("\(build) (its dependencies)")
            } else {
                // Half a state is worse than none: SwiftPM fetches it all again.
                try? files.removeItem(at: target)
                report.notes.append("\(build) wasn't cloned (\(failures.joined(separator: ", "))).")
            }
        }

        // Ignored in every worktree, whatever its commit's .gitignore says:
        // one made from a branch older than the ignore would count them as
        // changes, and `sc worktree remove` would refuse it.
        let exclude = main.appendingPathComponent(".git/info/exclude")
        let excluded = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        if !excluded.split(separator: "\n").contains(Substring(sourceKitExclude)) {
            do {
                try files.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
                let separator = excluded.isEmpty || excluded.hasSuffix("\n") ? "" : "\n"
                try (excluded + separator + sourceKitExclude + "\n").write(to: exclude, atomically: true, encoding: .utf8)
                report.excluded = true
            } catch {
                report.notes.append("Couldn't add \(sourceKitExclude) to \(exclude.path): \(error.localizedDescription)")
            }
        }
        for package in packages {
            let config = worktree.appendingPathComponent(package).appendingPathComponent(sourceKitConfigPath)
            guard !exists(config) else { continue }
            do {
                try files.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
                try sourceKitConfig.write(to: config, atomically: true, encoding: .utf8)
                report.configured += 1
            } catch {
                report.notes.append("Couldn't write \(config.path): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// An APFS clone: nothing is copied until one side changes a file, and
    /// then only that file. Nil when it worked, else why not. Never a copy
    /// instead, which would be the gigabytes this is meant to save.
    static func clone(_ source: URL, to target: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return error.localizedDescription
        }
        if Darwin.clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) == 0 { return nil }
        let code = errno
        return code == EXDEV ? "it's on another volume" : String(cString: strerror(code))
    }

    /// The files in a cloned package state that name the checkout's path:
    /// the state's record of each dependency and artifact, and each
    /// checkout's git remote (its copy in `repositories`). Left naming the
    /// main checkout, the worktree's would fetch through it, and break once
    /// that was cleaned.
    static func pathFiles(in state: URL) -> [URL] {
        let checkouts = state.appendingPathComponent("checkouts")
        let configs = ((try? FileManager.default.contentsOfDirectory(atPath: checkouts.path)) ?? [])
            .map { checkouts.appendingPathComponent($0).appendingPathComponent(".git/config") }
        return [state.appendingPathComponent("workspace-state.json")] + configs
    }

    static func rewritePaths(in state: URL, from main: URL, to worktree: URL) {
        for file in pathFiles(in: state) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let rewritten = rewrite(text, from: main, to: worktree)
            if rewritten != text { try? rewritten.write(to: file, atomically: true, encoding: .utf8) }
        }
    }

    static func rewrite(_ text: String, from main: URL, to worktree: URL) -> String {
        text.replacingOccurrences(of: slashed(main), with: slashed(worktree))
    }

    static func slashed(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasSuffix("/") ? path : path + "/"
    }

    /// The linked paths that are links in `root`: what `--on`'s sync must
    /// leave out, as a link to this Mac's files means nothing on another.
    static func links(in root: URL) -> [(name: String, target: URL)] {
        linked.compactMap { name in
            let url = root.appendingPathComponent(name)
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
            return (name, URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL)
        }
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}
