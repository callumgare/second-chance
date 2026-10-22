import Foundation
import Noora

/// The repo's linters: SwiftLint over the Swift code (`.swiftlint.yml`) and
/// markdownlint-cli2 over the docs (`.markdownlint.jsonc`). `sc lint` runs
/// them, and so do CI and `sc release`.
struct Lint {
    /// One linter, and how to run it from the repo root.
    struct Linter: Sendable {
        let name: String
        let tool: String
        let arguments: [String]
        /// How to get `tool` when it's missing.
        let install: String
    }

    /// Pinned, so CI and every Mac lint the same way.
    static let markdownlintVersion = "0.13.0"

    /// The docs that are linted. Listed rather than globbed from the root,
    /// which would walk the installers and build output (gigabytes) before
    /// the ignores in `.markdownlint-cli2.jsonc` apply.
    static let markdownFiles = ["README.md", "CONTRIBUTING.md", "AGENTS.md", "docs/*.md"]

    static let linters = [
        Linter(name: "SwiftLint", tool: "swiftlint", arguments: ["lint", "--strict", "--quiet"],
               install: "brew install swiftlint"),
        Linter(name: "markdownlint", tool: "npx",
               arguments: ["--yes", "markdownlint-cli2@\(markdownlintVersion)"] + markdownFiles,
               install: "brew install node"),
    ]

    /// Run every linter, each as its own step (its output shows when it
    /// fails). Returns the names of the ones that failed, or couldn't run.
    static func run(session: Session) async -> [String] {
        var failed: [String] = []
        for linter in linters {
            guard Proc.which(linter.tool) != nil else {
                session.ui.warning("\(linter.name) can't run: \(linter.tool) isn't installed.",
                                   next: TerminalText(stringLiteral: linter.install))
                failed.append(linter.name)
                continue
            }
            do {
                try await session.ui.logStep("\(linter.name)", log: "lint-\(linter.tool)",
                                             success: "\(linter.name) found nothing") { sink in
                    try await Proc.stream(linter.tool, linter.arguments, cwd: session.repo.root) { await sink.line($0) }
                }
            } catch {
                failed.append(linter.name)
            }
        }
        return failed
    }
}
