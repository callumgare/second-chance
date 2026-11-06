import Foundation
import Testing
@testable import SCKit

@Suite("Worktrees")
struct WorktreeTests {
    /// A main checkout and a worktree beside it, in a temporary folder
    /// (APFS, so clones work).
    struct Checkouts {
        let base: URL
        let main: URL
        let worktree: URL

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("sc-worktree-tests-\(UUID().uuidString)")
            main = base.appendingPathComponent("repo")
            worktree = base.appendingPathComponent("repo/.claude/worktrees/feature")
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        }

        func write(_ text: String, to path: String, in root: URL) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        func read(_ path: String, in root: URL) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    @Test("Only the main checkout's own paths are rewritten, not a sibling's that starts the same")
    func rewritesPaths() {
        let main = URL(fileURLWithPath: "/code/repo")
        let worktree = URL(fileURLWithPath: "/code/repo/.claude/worktrees/x")
        let text = #"{"path": "/code/repo/DerivedData/a", "other": "/code/repo-old/b"}"#
        #expect(Worktrees.rewrite(text, from: main, to: worktree)
            == #"{"path": "/code/repo/.claude/worktrees/x/DerivedData/a", "other": "/code/repo-old/b"}"#)
    }

    @Test("Ignored files are linked, caches cloned with their paths rewritten, and indexing turned off")
    func prepares() throws {
        let dirs = try Checkouts()
        defer { dirs.remove() }
        let main = dirs.main.path
        try dirs.write("notes", to: ".local/AGENTS.md", in: dirs.main)
        try dirs.write("KEY=1", to: ".env", in: dirs.main)
        try dirs.write("agent", to: ".claude/agents/a.md", in: dirs.main)
        // Left empty by a tool: replaced. Not empty: the worktree's own.
        try FileManager.default.createDirectory(at: dirs.worktree.appendingPathComponent(".local"), withIntermediateDirectories: true)
        try dirs.write("its own", to: ".claude/skills/s.md", in: dirs.worktree)
        try dirs.write("skill", to: ".claude/skills/s.md", in: dirs.main)

        try dirs.write(#"{"path": "\#(main)/DerivedData/SourcePackages/artifacts/x"}"#, to: "DerivedData/SourcePackages/workspace-state.json", in: dirs.main)
        try dirs.write("url = \(main)/DerivedData/SourcePackages/repositories/Yams", to: "DerivedData/SourcePackages/checkouts/Yams/.git/config", in: dirs.main)
        try dirs.write("pcm", to: "DerivedData/ModuleCache.noindex/A/x.pcm", in: dirs.main)
        try dirs.write("object", to: "DerivedData/Build/x.o", in: dirs.main)
        try dirs.write(#"{"path": "\#(main)/Packages/Kit/.build/artifacts/x"}"#, to: "Packages/Kit/.build/workspace-state.json", in: dirs.main)
        try dirs.write("zip", to: "Packages/Kit/.build/artifacts/x/f", in: dirs.main)
        try dirs.write("object", to: "Packages/Kit/.build/debug/x.o", in: dirs.main)
        try dirs.write("index", to: "Packages/Kit/.build/index-build/x", in: dirs.main)

        let report = Worktrees.prepare(dirs.worktree, main: dirs.main, packages: ["Packages/Kit", "Packages/Other"])
        #expect(Set(report.linked) == [".local", ".env", ".claude/agents"])
        #expect(report.notes.count == 1)
        #expect(try dirs.read(".local/AGENTS.md", in: dirs.worktree) == "notes")
        #expect(try dirs.read(".claude/skills/s.md", in: dirs.worktree) == "its own")

        let worktree = dirs.worktree.path
        #expect(try dirs.read("DerivedData/SourcePackages/workspace-state.json", in: dirs.worktree)
            == #"{"path": "\#(worktree)/DerivedData/SourcePackages/artifacts/x"}"#)
        #expect(try dirs.read("DerivedData/SourcePackages/checkouts/Yams/.git/config", in: dirs.worktree)
            == "url = \(worktree)/DerivedData/SourcePackages/repositories/Yams")
        // The main checkout's own are untouched.
        #expect(try dirs.read("DerivedData/SourcePackages/workspace-state.json", in: dirs.main).contains("\(main)/DerivedData"))
        #expect(try dirs.read("DerivedData/ModuleCache.noindex/A/x.pcm", in: dirs.worktree) == "pcm")
        #expect(!Worktrees.exists(dirs.worktree.appendingPathComponent("DerivedData/Build")))

        #expect(try dirs.read("Packages/Kit/.build/artifacts/x/f", in: dirs.worktree) == "zip")
        #expect(try dirs.read("Packages/Kit/.build/workspace-state.json", in: dirs.worktree).contains("\(worktree)/Packages/Kit"))
        #expect(!Worktrees.exists(dirs.worktree.appendingPathComponent("Packages/Kit/.build/debug")))
        #expect(!Worktrees.exists(dirs.worktree.appendingPathComponent("Packages/Kit/.build/index-build")))

        #expect(report.configured == 2)
        #expect(try dirs.read("Packages/Other/.sourcekit-lsp/config.json", in: dirs.worktree) == Worktrees.sourceKitConfig)
        #expect(try dirs.read(".git/info/exclude", in: dirs.main) == ".sourcekit-lsp/\n")

        let again = Worktrees.prepare(dirs.worktree, main: dirs.main, packages: ["Packages/Kit", "Packages/Other"])
        #expect(again.linked.isEmpty && again.cloned.isEmpty && again.configured == 0)
    }

    @Test("--on sends the paths under .local a command names, from where a worktree's link points")
    func sendsNamedLocalPaths() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sc-local-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let main = base.appendingPathComponent("main/.local")
        let worktree = base.appendingPathComponent("wt")
        try fm.createDirectory(at: main.appendingPathComponent("porting/x/inputs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: main.appendingPathComponent("porting/x/bundle"), withIntermediateDirectories: true)
        try Data().write(to: main.appendingPathComponent("porting/x/inputs/setup.exe"))
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: worktree.appendingPathComponent(".local"), withDestinationURL: main)

        let arguments = ["puppet", "start", "p", "--wrapp=.local/porting/x/bundle", "--", ".local/porting/x/inputs/setup.exe",
                         ".local/porting/missing.exe", "Bundles/x"]
        let named = Remote.localPaths(in: arguments, root: worktree, cwd: worktree)
        #expect(named == [".local/porting/x/bundle", ".local/porting/x/inputs/setup.exe"])

        let syncs = RuntimeCopy.localSyncs(named, root: worktree, target: Remote.Target(host: "mac", path: "~/wt"))
        let resolved = main.resolvingSymlinksInPath().path
        #expect(syncs.first?.suffix(2) == ["\(resolved)/porting/x/bundle/", "mac:~/wt/.local/porting/x/bundle/"])
        #expect(syncs.last?.suffix(2) == ["\(resolved)/porting/x/inputs/setup.exe", "mac:~/wt/.local/porting/x/inputs/setup.exe"])
        // Links inside are sent as links: nothing that follows them.
        #expect(!syncs.joined().contains { ["-L", "-k", "--copy-links", "--copy-dirlinks"].contains($0) })
    }

    @Test("git's porcelain listing is read, detached worktrees too")
    func parsesListing() {
        let listing = """
        worktree /code/repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /code/repo/.claude/worktrees/x
        HEAD 2222222222222222222222222222222222222222
        detached

        """
        let entries = WorktreeEntry.parse(listing)
        #expect(entries.map(\.path.path) == ["/code/repo", "/code/repo/.claude/worktrees/x"])
        #expect(entries.map(\.branch) == ["main", nil])
    }

    @Test("The hook does nothing on an ordinary checkout")
    func hookIgnoresSwitches() async throws {
        let dirs = try Checkouts()
        defer { dirs.remove() }
        let hook = dirs.base.appendingPathComponent("post-checkout")
        try Worktrees.hookScript.write(to: hook, atomically: true, encoding: .utf8)
        let switched = try await Proc.collect("/bin/sh", [hook.path, "1234abcd", "5678ef00", "1"], cwd: dirs.base)
        #expect(switched.succeeded && switched.output.isEmpty && switched.error.isEmpty)
    }
}
