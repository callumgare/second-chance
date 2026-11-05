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
        subcommands: [InstallersListCommand.self, InstallersMigrateCommand.self]
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
        if repo.installers.hasLegacyLayout(manifests: repo.manifests) {
            session.ui.warning("\(repo.installers.root.path) is still laid out by slug.", next: "Move it to the new layout: sc installers migrate")
        }
        guard !rows.isEmpty else {
            session.ui.line("No installers in \(repo.installers.root.path).")
            return
        }
        await session.ui.table(headers: ["Program", "Edition", "Files"], rows: rows)
    }
}

struct InstallersMigrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Move installers laid out by slug (<slug>/disk-1.iso) to where their manifests say.",
        discussion: """
        Reads the store's own <slug> folders and this checkout's installers/ \
        (a folder, or a link). Each disk-<n>.iso goes to its disc edition's \
        disc-<n> input, a disk-<n>-<name>.iso beside it as disc-<n>-<name>.iso, \
        and a disk-<n>.iso link to one of those is made again as disc-<n>.iso; \
        her-download*.exe goes to the Windows Her download edition's input and \
        a .dmg to the Mac one's; everything else to <bundle id>/extras/. \
        .DS_Store files are deleted. Shows what it would do unless given --yes; \
        anything it can't place is listed and left where it is.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Flag(name: [.customLong("yes"), .customShort("y")], help: "Do it, rather than show what it would do.")
    var yes = false

    func run() async throws {
        let session = try Session.start(global)
        let repo = session.repo, ui = session.ui
        let store = repo.installers
        let plan = InstallersMigration.plan(store: store, checkout: repo.root, manifests: repo.manifests)
        ui.line("Installers store: \(store.root.path)")
        if plan.isEmpty && plan.unplaced.isEmpty {
            ui.success("Nothing to move: the store is in its layout.")
            return
        }
        for line in plan.lines(store: store) { ui.line("  \(line)") }
        for note in plan.notes { ui.line("  note: \(note)") }
        if !plan.unplaced.isEmpty {
            ui.warning("Left where they are, as they couldn't be placed:")
            for item in plan.unplaced { ui.line("  \(store.display(item.item)): \(item.reason)") }
        }
        guard yes else {
            ui.info("Nothing was changed. Run it again with --yes to do it.")
            return
        }
        let failures = try plan.carryOut(store: store) { ui.detail($0) }
        guard failures.isEmpty else {
            throw SCError("Some of it couldn't be done:\n" + failures.map { "  \($0)" }.joined(separator: "\n"),
                          hints: ["Run it again to see what's left."])
        }
        ui.success("Moved the installers to the store's layout.")
    }
}
