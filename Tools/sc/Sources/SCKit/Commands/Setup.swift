import ArgumentParser
import Foundation
import Noora

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "One-time setup for a clone: tools, commit hook and shell completions.",
        discussion: """
        Checks the tools sc uses are installed, installs cog's commit-msg hook \
        (git hooks live in .git/ and can't be committed), and installs fish \
        completions when fish is your shell. Safe to run again.
        """
    )

    @OptionGroup var global: GlobalOptions

    static let tools: [(name: String, formula: String, purpose: String)] = [
        ("xcbeautify", "xcbeautify", "formats xcodebuild output"),
        ("xchtmlreport", "xctest-html-report", "HTML test reports"),
        ("cog", "cocogitto", "versions, changelog, commit lint"),
    ]

    func run() async throws {
        let session = try Session.start(global)
        let ui = session.ui

        let rows: [StyledTableRow] = Self.tools.map { tool in
            let found = Proc.which(tool.name) != nil
            return [.plain(tool.name), found ? .success("installed") : .danger("missing"),
                    .muted(found ? tool.purpose : "brew install \(tool.formula)")]
        }
        await ui.table(headers: ["Tool", "Status", ""], rows: rows)
        let missing = Self.tools.filter { Proc.which($0.name) == nil }

        if Proc.which("cog") != nil {
            try await ui.logStep("Install the commit-msg hook", log: "setup-hook", success: "commit-msg hook installed — non-conventional messages are rejected") { sink in
                try await Proc.stream("cog", ["install-hook", "--overwrite", "commit-msg"], cwd: session.repo.root) { await sink.line($0) }
            }
        }

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

        if !missing.isEmpty {
            throw SCError("Some tools are missing.", hints: missing.map { "brew install \($0.formula)" })
        }
        ui.success("Ready.")
    }
}

struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Delete caches and build output.",
        discussion: """
        wine-prefixes: the cached Wine prefix (start the next build from a fresh one). \
        build: DerivedData. wrapps: the wrapps dir. test-results: reports and result bundles. \
        With no target in a terminal, asks which.
        """
    )

    enum Target: String, CaseIterable, ExpressibleByArgument, CustomStringConvertible {
        case winePrefixes = "wine-prefixes"
        case build
        case wrapps
        case testResults = "test-results"
        var description: String { rawValue }
    }

    @OptionGroup var global: GlobalOptions
    @OptionGroup var wrapps: WrappsDirOptions

    @Flag(name: [.customLong("yes"), .customShort("y")], help: "Don't ask before deleting.")
    var yes = false

    @Argument(help: "What to delete: wine-prefixes, build, wrapps, test-results.")
    var targets: [Target] = []

    func run() async throws {
        let session = try Session.start(global)
        let ui = session.ui
        let paths: [Target: URL] = [
            .winePrefixes: Repo.winePrefixCache,
            .build: session.repo.derivedData,
            .wrapps: wrapps.resolve(session.repo),
            .testResults: session.repo.testResults,
        ]
        let sizes = await withTaskGroup(of: (Target, Int64).self) { group in
            for (target, url) in paths { group.addTask { (target, await Self.size(of: url)) } }
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
            guard let picked = ui.chooseSeveral("What should be deleted?", from: Target.allCases.map { Choice(target: $0, size: sizes[$0] ?? 0) }) else {
                throw SCError("Say what to delete: sc clean <target>…", hints: ["Targets: \(Target.allCases.map(\.rawValue).joined(separator: ", "))"])
            }
            chosen = picked.map(\.target)
        }

        if !yes, let confirmed = ui.confirm("Delete \(chosen.map(\.rawValue).joined(separator: ", "))?"), !confirmed {
            ui.line("Nothing deleted.")
            return
        }

        var rows: [[String]] = []
        for target in chosen {
            guard let url = paths[target] else { continue }
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                rows.append([target.rawValue, session.repo.display(url), ByteCountFormatter.string(fromByteCount: sizes[target] ?? 0, countStyle: .file)])
            } else {
                rows.append([target.rawValue, session.repo.display(url), "(nothing there)"])
            }
        }
        await ui.table(headers: ["Deleted", "Path", "Freed"], rows: rows)
    }

    static func size(of url: URL) async -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path),
              let result = try? await Proc.collect("/usr/bin/du", ["-sk", url.path]),
              let kb = result.output.split(separator: "\t").first.flatMap({ Int64($0) }) else { return 0 }
        return kb * 1024
    }
}
