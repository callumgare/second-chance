import Foundation
import WrappBuilder

/// A game as offered in a prompt.
struct GameChoice: Equatable, CustomStringConvertible {
    let game: CatalogGame
    var description: String { "\(game.title)  (\(game.programID))" }
}

/// Turning what the user typed into a game, with errors that list what's available.
enum Games {
    /// The game's disc images in the installers store: its disc edition's
    /// `disc-1`, `disc-2`…, in order; nil unless every one is there.
    static func discs(for game: CatalogGame, repo: Repo) -> InstallersStore.Found? {
        repo.manifest(of: game).flatMap { repo.installers.discs(of: $0) }
    }

    /// Games whose disc images are all in the installers store.
    static func withInstallers(repo: Repo) -> [CatalogGame] {
        Catalog.games.filter { discs(for: $0, repo: repo) != nil }
    }

    /// The game's Her Interactive downloads in the installers store, one
    /// for each of its Her editions there: the Windows installer (.exe) and
    /// the Mac download (.dmg), in the manifest's order.
    static func herDownloads(for game: CatalogGame, repo: Repo) -> [InstallersStore.Found] {
        repo.manifest(of: game).map { repo.installers.herDownloads(of: $0) } ?? []
    }

    /// Games with a Her Interactive download in the installers store.
    static func withHerDownloads(repo: Repo) -> [CatalogGame] {
        Catalog.games.filter { !herDownloads(for: $0, repo: repo).isEmpty }
    }

    static func withWrapps(in wrappsDir: URL, repo: Repo) -> [CatalogGame] {
        Catalog.games.filter { FileManager.default.fileExists(atPath: repo.wrapp(for: $0, in: wrappsDir).path) }
    }

    /// Resolve a program bundle id, `nancy-drew/blue-moon`, or the part
    /// after its last slash, `blue-moon`, when only one bundle's id ends so
    /// (`matching(_:)`). When several do, or none is given, asks the user to
    /// pick when there is a terminal to ask on, and otherwise explains what
    /// to pass. With none given, a bundle `--bundle` named is the program,
    /// and the one to pick from when it named several.
    static func resolve(
        _ id: String?,
        candidates: [CatalogGame],
        candidateKind: String,
        command: String,
        ui: UI,
        extras: [String] = ExtraBundleOptions.ids
    ) throws -> CatalogGame {
        let available = candidates.isEmpty
            ? "No programs have \(candidateKind) yet."
            : "Programs with \(candidateKind): \(candidates.map(\.programID).joined(separator: ", "))"
        guard let id else {
            // `--bundle` without a program: the program is its bundle's, or
            // one of theirs.
            let extras = extras.compactMap { id in Catalog.games.first { $0.programID == id } }
            if extras.count == 1, let only = extras.first { return only }
            if extras.count > 1 {
                if let choice = try ui.choose("Which program?", from: extras.map(GameChoice.init)) { return choice.game }
                throw SCError("--bundle named more than one program, so name one: sc \(command) <program-bundle-id>.",
                              hints: ["Programs --bundle named: \(extras.map(\.programID).joined(separator: ", "))"])
            }
            if let choice = try ui.choose("Which program?", from: candidates.map(GameChoice.init)) {
                return choice.game
            }
            throw SCError("Name a program: sc \(command) <program-bundle-id>.", hints: [available])
        }
        let matches = matching(id)
        if matches.count == 1, let game = matches.first { return game }
        if matches.count > 1 {
            // Those the command can use first, so the likelier pick is on top.
            let ordered = matches.filter { candidates.contains($0) } + matches.filter { !candidates.contains($0) }
            if let choice = try ui.choose("Which '\(id)'?", from: ordered.map(GameChoice.init)) {
                return choice.game
            }
            throw SCError("More than one program is called '\(id)': \(ordered.map(\.programID).joined(separator: ", ")).",
                          hints: ["Name one by its full id: sc \(command) \(ordered[0].programID)."])
        }

        var hints: [String] = []
        if let guess = closest(to: id) { hints.append("Did you mean \(guess.programID)?") }
        hints.append(available)
        throw SCError("No program called '\(id)'.", hints: hints)
    }

    /// The programs `id` names: the one whose bundle id it is, or else every
    /// one whose bundle id ends in `/<id>`.
    static func matching(_ id: String, in games: [CatalogGame] = Catalog.games) -> [CatalogGame] {
        if let exact = games.first(where: { $0.programID == id }) { return [exact] }
        return games.filter { $0.programID.hasSuffix("/" + id) }
    }

    /// The known program that most resembles `input`, by its full bundle
    /// id when `input` has a slash and by the part after it when not.
    static func closest(to input: String) -> CatalogGame? {
        let name: (CatalogGame) -> String = input.contains("/") ? { $0.programID } : { $0.slug }
        let scored = Catalog.games.map { ($0, distance(name($0), input)) }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= max(2, input.count / 3) else {
            return Catalog.games.first { name($0).contains(input) || input.contains(name($0)) }
        }
        return best.0
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
