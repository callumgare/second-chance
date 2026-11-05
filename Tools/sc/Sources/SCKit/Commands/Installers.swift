import ArgumentParser
import Foundation
import WrappBuilder

struct InstallersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "installers",
        abstract: "The Mac's installers store: the disc images and downloads test builds read.",
        discussion: """
        One store per Mac, at /Users/Shared/second-chance/installers (or \
        $SECOND_CHANCE_INSTALLERS), laid out as <bundle id>/<edition>/<input>.<ext>. \
        See docs/testing.md#the-installers-store.
        """,
        subcommands: [InstallersListCommand.self]
    )
}

struct InstallersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the editions whose installers are all in the store."
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let session = try Session.start(global)
        let repo = session.repo
        let rows = repo.manifests.flatMap { manifest in
            repo.installers.found(manifest).map { found in
                [found.program, found.edition, found.files.map { repo.installers.display($0) }.joined(separator: ", ")]
            }
        }
        guard !rows.isEmpty else {
            session.ui.line("No installers in \(repo.installers.root.path).")
            return
        }
        await session.ui.table(headers: ["Program", "Edition", "Files"], rows: rows)
    }
}

extension InstallersStore {
    /// A path in the store relative to it; any other, whole.
    func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path, prefix = root.standardizedFileURL.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
