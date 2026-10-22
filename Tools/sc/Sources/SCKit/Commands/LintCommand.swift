import ArgumentParser
import Foundation

struct LintCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lint",
        abstract: "Lint the Swift code (SwiftLint) and the docs (markdownlint).",
        discussion: """
        SwiftLint runs with --strict, so a warning fails too; its rules are in \
        .swiftlint.yml. markdownlint-cli2 lints README.md, CONTRIBUTING.md, \
        AGENTS.md and docs/*.md, with the rules in .markdownlint.jsonc. CI runs \
        this, and sc release asks before releasing with lint failures. \
        `swiftlint --fix` fixes much of what SwiftLint finds.
        """
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let session = try Session.start(global)
        let failed = await Lint.run(session: session)
        guard failed.isEmpty else {
            throw SCError("Lint failed: \(failed.joined(separator: ", ")).", alreadyReported: false)
        }
        session.ui.success("Lint passed.")
    }
}
