import AppKit
import ArgumentParser
import Foundation
import WrappBuilder
import WrappFormat

struct StoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "store",
        abstract: "List and remove the stores builds and apps keep outside any app.",
        discussion: "docs/wrappfile.md#stores describes stores; sc clean stores clears them by retention.",
        subcommands: [StoreListCommand.self, StoreRemoveCommand.self]
    )

    /// Where this Mac's stores are. Session stores end with their build or
    /// launch, so there's never one to find.
    static var locations: StoreLocations {
        StoreLocations.current(session: FileManager.default.temporaryDirectory.appendingPathComponent("sc-no-session-stores"))
    }

    /// The stores on this Mac, each with its lock as the shipped modules
    /// declare it when no build has recorded one yet.
    static func found(_ repo: Repo) -> [FoundStore] {
        let modules = (try? ModuleLoader(root: repo.modules).loadAll().get()) ?? []
        let declared = StoreDeclarations(of: modules)
        return StoreInventory.all(in: locations, declaredLocks: declared.stores.compactMapValues(\.lock))
    }

    /// Whether a build or an app is using `store`: its lock held, or, for a
    /// wrapp's own store, the wrapp running.
    static func isInUse(_ store: FoundStore) -> Bool {
        if StoreInventory.isInUse(store, in: locations) { return true }
        guard let app = store.appID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty
    }

    static func rows(_ stores: [FoundStore]) async -> [[String]] {
        var rows: [[String]] = []
        for store in stores {
            let size = await CleanCommand.size(of: store.folder)
            let inUse = isInUse(store) ? "in use" : ""
            rows.append([store.fullName, store.appID ?? "(every app)", store.retention,
                         ByteCountFormatter.string(fromByteCount: size, countStyle: .file), inUse,
                         (store.folder.path as NSString).abbreviatingWithTildeInPath])
        }
        return rows
    }
}

struct StoreListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the kept and cache stores on this Mac, with their sizes and whether one is in use."
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: "Only stores with this retention: keep or cache.")
    var retention: String?

    @Option(help: "Only this app's own stores (its bundle id).")
    var app: String?

    func run() async throws {
        let session = try Session.start(global)
        let stores = StoreCommand.found(session.repo)
            .filter { retention == nil || $0.retention == retention }
            .filter { app == nil || $0.appID == app }
        if stores.isEmpty {
            session.ui.line("No stores.")
            return
        }
        await session.ui.table(headers: ["Store", "App", "Retention", "Size", "In use", "Path"], rows: await StoreCommand.rows(stores))
    }
}

struct StoreRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a store, as owner:name, with what it holds.",
        discussion: """
        An app's store is removed for every app that has one unless --app names \
        one. A store whose lock is held (a build or an app is using it) is left \
        alone. Removing steam:sign-in signs every Steam app out; an app's \
        app:wine-documents holds the player's saves.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Flag(name: [.customLong("yes"), .customShort("y")], help: "Don't ask before removing.")
    var yes = false

    @Option(help: "Only this app's (its bundle id).")
    var app: String?

    @Argument(help: "The store, as owner:name (steam:client).")
    var store: String

    func run() async throws {
        let session = try Session.start(global)
        let found = StoreCommand.found(session.repo).filter { $0.fullName == store && (app == nil || $0.appID == app) }
        guard !found.isEmpty else {
            throw SCError("There's no store \(store)\(app.map { " for \($0)" } ?? "").", hints: ["sc store list shows the stores there are."])
        }
        try await StoreCommand.remove(found, yes: yes, session: session)
    }
}

extension StoreCommand {
    /// `stores` removed once confirmed, apart from any in use, with a table
    /// of what went.
    static func remove(_ stores: [FoundStore], yes: Bool, session: Session) async throws {
        let ui = session.ui
        let busy = stores.filter(isInUse)
        for store in busy {
            ui.warning("\(store.fullName)\(store.appID.map { " (\($0))" } ?? "") is in use, so it's left alone.",
                       next: "Quit the app or build using it, then try again.")
        }
        let removing = stores.filter { !busy.contains($0) }
        guard !removing.isEmpty else { return }
        if !yes {
            let names = removing.map { "\($0.fullName)\($0.appID.map { " (\($0))" } ?? "")" }
            guard let confirmed = try ui.confirm("Remove \(names.joined(separator: ", "))?") else {
                throw SCError("Nothing removed: there's no terminal to confirm on.", hints: ["Pass -y to remove without asking."])
            }
            if !confirmed {
                ui.line("Nothing removed.")
                return
            }
        }
        let rows = await self.rows(removing).map { Array($0.prefix(4)) }
        for store in removing { try StoreInventory.remove(store) }
        await ui.table(headers: ["Removed", "App", "Retention", "Freed"], rows: rows)
    }
}
