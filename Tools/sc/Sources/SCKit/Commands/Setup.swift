import ArgumentParser
import Foundation
import WrappFormat
import Noora

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "One-time setup for a clone: tools, git hooks, shell completions and editor highlighting.",
        discussion: """
        Checks the tools sc uses are installed, installs cog's commit-msg hook \
        and the post-checkout hook that prepares new worktrees (git hooks live \
        in .git/ and can't be committed), installs fish \
        completions when fish is your shell, and links Wrappfile highlighting \
        (Tools/vscode-wrappfile) into VS Code when it's installed. Safe to run again.
        """
    )

    @OptionGroup var global: GlobalOptions

    static let tools: [(name: String, formula: String, purpose: String)] = [
        ("xcbeautify", "xcbeautify", "formats xcodebuild output"),
        ("xchtmlreport", "xctesthtmlreport", "HTML test reports"),
        ("cog", "cocogitto", "versions, changelog, commit lint"),
        ("swiftlint", "swiftlint", "lints the Swift code (sc lint)"),
        ("npx", "node", "runs markdownlint on the docs (sc lint)"),
    ]
    /// Needed only to cut a release, so their absence isn't a failure.
    static let releaseTools: [(name: String, formula: String, purpose: String)] = [
        ("sentry-cli", "getsentry/tools/sentry-cli", "uploads debug symbols (sc release only)"),
    ]

    func run() async throws {
        let session = try Session.start(global)
        let ui = session.ui

        let rows: [StyledTableRow] = Self.tools.map { tool in
            let found = Proc.which(tool.name) != nil
            return [.plain(tool.name), found ? .success("installed") : .danger("missing"),
                    .muted(found ? tool.purpose : "brew install \(tool.formula)")]
        } + Self.releaseTools.map { tool in
            let found = Proc.which(tool.name) != nil
            return [.plain(tool.name), found ? .success("installed") : .muted("not installed"),
                    .muted(found ? tool.purpose : "brew install \(tool.formula) — \(tool.purpose)")]
        }
        await ui.table(headers: ["Tool", "Status", ""], rows: rows)
        let missing = Self.tools.filter { Proc.which($0.name) == nil }

        if Proc.which("cog") != nil {
            try await ui.logStep("Install the commit-msg hook", log: "setup-hook", success: "commit-msg hook installed — non-conventional messages are rejected") { sink in
                try await Proc.stream("cog", ["install-hook", "--overwrite", "commit-msg"], cwd: session.repo.root) { await sink.line($0) }
            }
        }

        try await installWorktreeHook(session)

        let shell = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "").lastPathComponent
        if shell == "fish" {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/fish/completions")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("sc.fish")
            try SC.completionScript(for: .fish).write(to: file, atomically: true, encoding: .utf8)
            ui.line(ui.format("\(.success("✔︎ fish completions installed in \(file.path)"))"))
        } else if !shell.isEmpty {
            ui.detail("Completions: sc --generate-completion-script \(shell) (see its output for where to put it).")
        }

        // Wrappfile highlighting: a grammar with no code, linked rather than
        // installed, so an edit to it shows on VS Code's next window reload.
        let extensions = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vscode/extensions")
        if FileManager.default.fileExists(atPath: extensions.path) {
            let link = extensions.appendingPathComponent("second-chance.wrappfile")
            let target = session.repo.root.appendingPathComponent("Tools/vscode-wrappfile")
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try FileManager.default.removeItem(at: link)
            }
            if FileManager.default.fileExists(atPath: link.path) {
                ui.detail("VS Code: \(link.path) isn't a link to this clone; left alone.")
            } else {
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                ui.line(ui.format("\(.success("✔︎ Wrappfile highlighting linked into VS Code (reload its window)"))"))
            }
        }

        if !missing.isEmpty {
            throw SCError("Some tools are missing.", hints: missing.map { "brew install \($0.formula)" })
        }
        ui.success("Ready.")
    }

    /// The post-checkout hook that prepares a new worktree, however it was
    /// made (docs/dev-cli.md#worktrees). Hooks are shared by every
    /// worktree, so this is once per clone. A hook of someone else's is
    /// left alone.
    func installWorktreeHook(_ session: Session) async throws {
        let path = try await Worktrees.git(["rev-parse", "--path-format=absolute", "--git-path", "hooks/post-checkout"], in: session.repo.root)
        let hook = URL(fileURLWithPath: path)
        if let existing = try? String(contentsOf: hook, encoding: .utf8), !existing.contains(Worktrees.hookMarker) {
            session.ui.detail("Worktrees: \(hook.path) is another hook, so new worktrees aren't prepared by themselves; run sc worktree prepare in each.")
            return
        }
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Worktrees.hookScript.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        session.ui.line(session.ui.format("\(.success("✔︎ post-checkout hook installed — new worktrees are prepared (sc worktree prepare)"))"))
    }
}

struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Delete caches and build output.",
        discussion: """
        layers: the layer cache, the Wine prefix among it (start the next build from scratch; \
        wine-prefixes is another name for it). \
        build: DerivedData, the main checkout's and every worktree's, and the folders Xcode's window built \
        them into in ~/Library/Developer/Xcode/DerivedData; one a running process uses (a build, or something \
        run from it) is left alone. wrapps: the wrapps dir. test-results: reports and result bundles. \
        steam-session: the saved Steam sign-in (signs every Steam wrapp out, like Sign Out of Steam). \
        steam-client: the cached Steam client (the next Steam build downloads Steam's update again). \
        engines: the engine store, the engines builds prepared (the next build that needs one prepares it \
        again, from downloads when they are still there). \
        downloads: what building Second Chance and its builds downloaded (AutoIt, game patches, engines' \
        and free games' files, Big Fish's Game Manager installer), fetched and checked again when next needed. \
        stores: the stores builds and apps keep (sc store list), those with --retention's retention, cache \
        by default (Steam's client among them); --retention keep takes the kept ones, every app's saves and \
        Steam's sign-in among them. A store in use is left alone. \
        With no target in a terminal, asks which. Without a terminal, deletes only with -y.
        """
    )

    enum Target: String, CaseIterable, ExpressibleByArgument, CustomStringConvertible {
        case layers
        /// What `layers` was called when the prefix was the only cache.
        case winePrefixes = "wine-prefixes"
        case build
        case wrapps
        case testResults = "test-results"
        case steamSession = "steam-session"
        case steamClient = "steam-client"
        case engines
        case downloads
        case stores
        var description: String { rawValue }
        static var allCases: [Target] { [.layers, .build, .wrapps, .testResults, .steamSession, .steamClient, .engines, .downloads, .stores] }
    }

    @OptionGroup var global: GlobalOptions
    @OptionGroup var wrapps: WrappsDirOptions

    @Flag(name: [.customLong("yes"), .customShort("y")], help: "Don't ask before deleting.")
    var yes = false

    @Option(help: "For stores: which retention's to delete, cache or keep.")
    var retention: Retention = .cache

    enum Retention: String, ExpressibleByArgument { case cache, keep }

    @Argument(help: "What to delete: layers, build, wrapps, test-results, steam-session, steam-client, engines, downloads, stores.")
    var targets: [Target] = []

    func run() async throws {
        let session = try Session.start(global)
        let ui = session.ui
        let targets = self.targets.map { $0 == .winePrefixes ? .layers : $0 }
        let stores = StoreCommand.found(session.repo).filter { $0.retention == retention.rawValue }
        let paths: [Target: [URL]] = [
            .layers: [Repo.layerStore, Repo.formerWinePrefixCache],
            .build: await Self.derivedData(session.repo),
            .wrapps: [wrapps.resolve(session.repo)],
            .testResults: [session.repo.testResults],
            .steamSession: Repo.steamSession,
            .steamClient: Repo.steamClientCache,
            .engines: [Repo.engineStore],
            .downloads: Repo.downloads,
            .stores: stores.map(\.folder),
        ]
        // Only what's on offer is measured: everything when asking which,
        // else just what was named.
        let measured = targets.isEmpty ? Target.allCases : targets
        let sizes = await withTaskGroup(of: (Target, Int64).self) { group in
            for target in measured {
                let urls = paths[target] ?? []
                group.addTask { (target, await Self.size(of: urls)) }
            }
            var result: [Target: Int64] = [:]
            for await (target, size) in group { result[target] = size }
            return result
        }

        var chosen = targets
        if chosen.isEmpty {
            struct Choice: Equatable, CustomStringConvertible {
                let target: Target
                let size: Int64
                var description: String { "\(target.rawValue)  (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))" }
            }
            guard let picked = try ui.chooseSeveral("What should be deleted?", from: Target.allCases.map { Choice(target: $0, size: sizes[$0] ?? 0) }) else {
                throw SCError("Say what to delete: sc clean <target>…", hints: ["Targets: \(Target.allCases.map(\.rawValue).joined(separator: ", "))"])
            }
            chosen = picked.map(\.target)
        }

        if !yes {
            // No terminal to ask on (nil) is no answer, not a yes.
            guard let confirmed = try ui.confirm("Delete \(chosen.map(\.rawValue).joined(separator: ", "))?") else {
                throw SCError("Nothing deleted: there's no terminal to confirm on.", hints: ["Pass -y to delete without asking."])
            }
            if !confirmed {
                ui.line("Nothing deleted.")
                return
            }
        }

        var rows: [[String]] = []
        for target in chosen {
            if target == .stores {
                let busy = stores.filter(StoreCommand.isInUse)
                for store in busy {
                    ui.warning("\(store.fullName)\(store.appID.map { " (\($0))" } ?? "") is in use, so it's left alone.")
                }
                let removing = stores.filter { !busy.contains($0) }
                for store in removing { try StoreInventory.remove(store) }
                rows.append([target.rawValue, removing.isEmpty ? "(nothing there)" : "\(removing.count) \(retention.rawValue) stores",
                             removing.isEmpty ? "" : ByteCountFormatter.string(fromByteCount: sizes[target] ?? 0, countStyle: .file)])
                continue
            }
            var urls = (paths[target] ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
            var freed = sizes[target] ?? 0
            if target == .build {
                // A build writing to it, or the app run from it, would fail
                // or crash halfway; it's the next clean's.
                var busy: [URL] = []
                for url in urls {
                    let users = await FolderUsers.of(url)
                    guard !users.isEmpty else { continue }
                    busy.append(url)
                    let named = users.prefix(3).map { "\($0.name) (pid \($0.pid))" }.joined(separator: ", ")
                    ui.warning("\(session.repo.display(url)) is in use by \(named)\(users.count > 3 ? " and \(users.count - 3) more" : ""), so it's left alone.")
                }
                if !busy.isEmpty {
                    urls.removeAll { busy.contains($0) }
                    freed = await Self.size(of: urls)
                }
            }
            if urls.isEmpty {
                rows.append([target.rawValue, "", "(nothing there)"])
                continue
            }
            for url in urls {
                try FileManager.default.removeItem(at: url)
            }
            let shown = urls.count == 1 ? session.repo.display(urls[0])
                : target == .build ? "\(urls.count) DerivedData folders"
                : "\(urls.count) items in \(session.repo.display(urls[0].deletingLastPathComponent()))"
            rows.append([target.rawValue, shown, ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)])
        }
        await ui.table(headers: ["Deleted", "Path", "Freed"], rows: rows)
    }

    /// Every checkout's DerivedData: the main checkout's and each worktree's,
    /// and the folders Xcode's window built them into (`XcodeDerivedData`).
    /// Outside a git repo (a runtime copy), just this one's.
    static func derivedData(_ repo: Repo) async -> [URL] {
        guard let main = try? await Worktrees.mainCheckout(of: repo.root),
              let listing = try? await Worktrees.git(["worktree", "list", "--porcelain"], in: main) else {
            return [repo.derivedData]
        }
        let checkouts = WorktreeEntry.parse(listing).map(\.path)
        let all = checkouts.contains(repo.root.standardizedFileURL) ? checkouts : [repo.root] + checkouts
        let projects = (try? await Worktrees.git(["ls-files", "--", "*.xcodeproj/project.pbxproj"], in: main)) ?? ""
        let names = Set(projects.split(separator: "\n").map {
            (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent.replacingOccurrences(of: ".xcodeproj", with: "")
        })
        return all.map { $0.appendingPathComponent("DerivedData") } + XcodeDerivedData.folders(checkouts: all, projects: names)
    }

    /// What deleting them all would free: APFS clones count once, and not at
    /// all while a clone outside them still holds the blocks (`DiskUsage`).
    static func size(of urls: [URL]) async -> Int64 {
        await Task.detached { DiskUsage.freed(by: urls) }.value
    }

    static func size(of url: URL) async -> Int64 {
        await size(of: [url])
    }
}
