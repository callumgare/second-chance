import ArgumentParser
import Foundation
import Noora

struct WorktreeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "worktree",
        abstract: "Make, prepare, list and remove extra checkouts (git worktrees).",
        discussion: """
        A worktree made by sc, or by anything else once sc setup has installed \
        its post-checkout hook (Claude Code's among them), links .local, .env \
        and .claude's agents and skills to the main checkout's, starts from \
        clones of its fetched packages and module cache, and has SourceKit-LSP's \
        background indexing off. See docs/dev-cli.md#worktrees.
        """,
        subcommands: [WorktreeAddCommand.self, WorktreePrepareCommand.self, WorktreeListCommand.self, WorktreeRemoveCommand.self],
        defaultSubcommand: WorktreeListCommand.self
    )

    /// A worktree named on the command line: a path, or a name under the
    /// main checkout's worktrees directory.
    static func resolve(_ given: String, main: URL) -> URL {
        let path = (given as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if !given.contains("/"), !FileManager.default.fileExists(atPath: url.path) {
            return main.appendingPathComponent(Worktrees.directory).appendingPathComponent(given, isDirectory: true)
        }
        return url.standardizedFileURL
    }

    static func show(_ report: Worktrees.Report, for worktree: URL, ui: UI) {
        if !report.linked.isEmpty { ui.detail("Linked to the main checkout's: \(report.linked.joined(separator: ", "))") }
        if !report.cloned.isEmpty { ui.detail("Cloned from the main checkout's: \(report.cloned.joined(separator: ", "))") }
        if report.configured > 0 { ui.detail("SourceKit-LSP's background indexing turned off in \(report.configured) packages") }
        if report.excluded { ui.detail("\(Worktrees.sourceKitExclude) added to the repo's info/exclude, for every worktree") }
        for note in report.notes { ui.warning("\(note)") }
        if report.linked.isEmpty, report.cloned.isEmpty, report.configured == 0, !report.excluded, report.notes.isEmpty {
            ui.detail("\(worktree.path) was already prepared.")
        }
    }
}

struct WorktreeAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Make a worktree in .claude/worktrees/<name> and prepare it.",
        discussion: """
        Like git worktree add: with no --branch and no commit, checks out the \
        branch <name>, made from HEAD if there's none.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Its name, the folder in .claude/worktrees.")
    var name: String

    @Argument(help: "The commit or branch to start from (default HEAD).")
    var commit: String?

    @Option(name: [.customShort("b"), .long], help: "Make a new branch of this name for it.")
    var branch: String?

    @Flag(help: "Check the commit out detached, on no branch.")
    var detach = false

    func validate() throws {
        if name.contains("/") { throw ValidationError("A name, not a path: it's made in \(Worktrees.directory)/<name>.") }
        if detach && branch != nil { throw ValidationError("--detach or --branch, not both.") }
    }

    func run() async throws {
        let session = try Session.start(global)
        let ui = session.ui
        let main = try await Worktrees.mainCheckout(of: session.repo.root)
        let worktree = main.appendingPathComponent(Worktrees.directory).appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: worktree.path) else {
            throw SCError("\(worktree.path) is already there.", hints: ["Prepare it again with: sc worktree prepare \(name)"])
        }
        var args = ["-C", main.path, "worktree", "add"]
        if let branch { args += ["-b", branch] }
        if detach { args.append("--detach") }
        args.append(worktree.path)
        if let commit { args.append(commit) }
        let added = try await Proc.collect("git", args, env: [Worktrees.preparingVariable: "1"])
        guard added.succeeded else {
            throw SCError("git worktree add failed: \(added.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let report = Worktrees.prepare(worktree, main: main, packages: try await Worktrees.packageDirectories(in: worktree))
        WorktreeCommand.show(report, for: worktree, ui: ui)
        ui.success("Made \(worktree.path)")
    }
}

struct WorktreePrepareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare",
        abstract: "Link, clone and configure what a worktree lacks (the hook runs this).",
        discussion: """
        Only what isn't there already, so it's safe to run again: on a worktree \
        made before the hook, or after a clean.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The worktree: a path, or a name in .claude/worktrees (default: the one sc is run in).")
    var worktree: String?

    func run() async throws {
        let session = try Session.start(global)
        let main = try await Worktrees.mainCheckout(of: session.repo.root)
        let given = worktree.map { WorktreeCommand.resolve($0, main: main) } ?? session.repo.root
        guard FileManager.default.fileExists(atPath: given.path) else { throw SCError("There's no worktree at \(given.path).") }
        let top = try await Worktrees.topLevel(of: given)
        guard try await Worktrees.mainCheckout(of: top) == main else {
            throw SCError("\(top.path) isn't a worktree of \(main.path).")
        }
        guard top != main else {
            throw SCError("\(top.path) is the main checkout, which the others are prepared from.")
        }
        let report = Worktrees.prepare(top, main: main, packages: try await Worktrees.packageDirectories(in: top))
        WorktreeCommand.show(report, for: top, ui: session.ui)
    }
}

struct WorktreeListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the worktrees, whether each is merged into main and has changes (the default)."
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let session = try Session.start(global)
        let main = try await Worktrees.mainCheckout(of: session.repo.root)
        let listing = try await Worktrees.git(["worktree", "list", "--porcelain"], in: main)
        var rows: [StyledTableRow] = []
        for entry in WorktreeEntry.parse(listing) where entry.path != main {
            let state = await WorktreeState.read(entry)
            rows.append([
                .plain(session.repo.display(entry.path)),
                .plain(entry.branch ?? "detached at \(entry.head.prefix(8))"),
                state.merged ? .success("merged") : .muted("not merged"),
                state.dirty ? .danger("changes") : .muted("clean"),
            ])
        }
        if rows.isEmpty {
            session.ui.detail("No worktrees but the main checkout.")
            return
        }
        await session.ui.table(headers: ["Worktree", "Branch", "Into main", "Changes"], rows: rows)
    }
}

struct WorktreeRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a worktree and its build output, once its work is merged.",
        discussion: """
        Refuses while it has changes or commits main doesn't, unless --force. \
        Its links to the main checkout's files are removed first, and the \
        files themselves left alone.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The worktree: a path, or a name in .claude/worktrees.")
    var worktree: String

    @Flag(help: "Remove it even with changes or commits main doesn't have, which are lost.")
    var force = false

    @Flag(help: "Delete its branch too (only when merged, unless --force).")
    var deleteBranch = false

    func run() async throws {
        let session = try Session.start(global)
        let ui = session.ui
        let main = try await Worktrees.mainCheckout(of: session.repo.root)
        let given = WorktreeCommand.resolve(worktree, main: main)
        let listing = try await Worktrees.git(["worktree", "list", "--porcelain"], in: main)
        let resolved = given.resolvingSymlinksInPath()
        guard let entry = WorktreeEntry.parse(listing).first(where: { $0.path.resolvingSymlinksInPath() == resolved }) else {
            throw SCError("\(given.path) isn't one of this repo's worktrees.", hints: ["sc worktree list shows them."])
        }
        guard entry.path != main else { throw SCError("That's the main checkout.") }
        if session.repo.root.resolvingSymlinksInPath().path.hasPrefix(resolved.path + "/") || session.repo.root.resolvingSymlinksInPath() == resolved {
            throw SCError("sc is running from inside that worktree.", hints: ["Run it from the main checkout: \(main.path)/sc worktree remove \(worktree)"])
        }

        let state = await WorktreeState.read(entry)
        if !force {
            var problems: [String] = []
            if state.dirty { problems.append("it has changes that aren't committed") }
            if !state.merged { problems.append("it has commits main doesn't") }
            if !problems.isEmpty {
                throw SCError("\(given.path) wasn't removed: \(problems.joined(separator: " and ")).",
                              hints: ["Pass --force to remove it anyway, losing them."])
            }
        }

        // git doesn't follow links when it deletes, but nothing of the main
        // checkout's should be in reach when a folder is deleted.
        for link in Worktrees.links(in: entry.path) {
            try FileManager.default.removeItem(at: entry.path.appendingPathComponent(link.name))
        }
        let removed = try await Proc.collect("git", ["-C", main.path, "worktree", "remove"] + (force ? ["--force"] : []) + [entry.path.path])
        guard removed.succeeded else {
            throw SCError("git worktree remove failed: \(removed.error.trimmingCharacters(in: .whitespacesAndNewlines))",
                          hints: ["Its links to the main checkout's files are already gone; sc worktree prepare puts them back."])
        }
        ui.success("Removed \(entry.path.path)")

        if deleteBranch, let branch = entry.branch {
            let deleted = try await Proc.collect("git", ["-C", main.path, "branch", force ? "-D" : "-d", branch])
            if deleted.succeeded {
                ui.detail("Deleted the branch \(branch).")
            } else {
                ui.warning("The branch \(branch) is still there: \(deleted.error.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }
}

/// One worktree in `git worktree list --porcelain`.
struct WorktreeEntry: Equatable {
    let path: URL
    let head: String
    /// Without `refs/heads/`; nil when detached.
    let branch: String?

    static func parse(_ porcelain: String) -> [WorktreeEntry] {
        porcelain.components(separatedBy: "\n\n").compactMap { block in
            var path: String?
            var head = ""
            var branch: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("HEAD ") { head = String(line.dropFirst("HEAD ".count)) }
                if line.hasPrefix("branch ") {
                    let ref = line.dropFirst("branch ".count)
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
                }
            }
            guard let path else { return nil }
            return WorktreeEntry(path: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL, head: head, branch: branch)
        }
    }
}

struct WorktreeState {
    /// Its HEAD is in main: nothing would be lost with it.
    let merged: Bool
    /// Changes, or files git doesn't ignore, that aren't committed.
    let dirty: Bool

    static func read(_ entry: WorktreeEntry) async -> WorktreeState {
        let merged = (try? await Proc.collect("git", ["-C", entry.path.path, "merge-base", "--is-ancestor", "HEAD", "main"]))?.succeeded ?? false
        let status = try? await Proc.collect("git", ["-C", entry.path.path, "status", "--porcelain"])
        let dirty = status.map { !$0.succeeded || !$0.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
        return WorktreeState(merged: merged, dirty: dirty)
    }
}
