import Foundation
import GameCatalog

/// A game as offered in a prompt.
struct GameChoice: Equatable, CustomStringConvertible {
    let game: CatalogGame
    var description: String { "\(game.title)  (\(game.slug))" }
}

/// Turning what the user typed into a game, with errors that list what's available.
enum Games {
    /// Slugs with a `disk-1.iso` in the installers directory.
    static func withInstallers(in installersDir: URL) -> [CatalogGame] {
        Catalog.games.filter {
            FileManager.default.fileExists(atPath: installersDir.appendingPathComponent("\($0.slug)/disk-1.iso").path)
        }
    }

    static func withWrapps(in wrappsDir: URL, repo: Repo) -> [CatalogGame] {
        Catalog.games.filter { FileManager.default.fileExists(atPath: repo.wrapp(for: $0, in: wrappsDir).path) }
    }

    /// Resolve a slug. With no slug, asks the user to pick from `candidates`
    /// when there is a terminal to ask on, and otherwise explains what to pass.
    static func resolve(
        _ slug: String?,
        candidates: [CatalogGame],
        candidateKind: String,
        command: String,
        ui: UI
    ) throws -> CatalogGame {
        guard let slug else {
            if let choice = ui.choose("Which game?", from: candidates.map(GameChoice.init)) {
                return choice.game
            }
            throw SCError(
                "Name a game: sc \(command) <slug>.",
                hints: candidates.isEmpty
                    ? ["No games have \(candidateKind) yet."]
                    : ["Games with \(candidateKind): \(candidates.map(\.slug).joined(separator: ", "))"]
            )
        }
        if let game = Catalog.game(slug: slug) { return game }

        var hints: [String] = []
        if let guess = closest(to: slug) { hints.append("Did you mean \(guess.slug)?") }
        hints.append(candidates.isEmpty
            ? "No games have \(candidateKind) yet."
            : "Games with \(candidateKind): \(candidates.map(\.slug).joined(separator: ", "))")
        throw SCError("No game called '\(slug)'.", hints: hints)
    }

    /// The known slug that most resembles `input`, if any is close.
    static func closest(to input: String) -> CatalogGame? {
        let scored = Catalog.games.map { ($0, distance($0.slug, input)) }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= max(2, input.count / 3) else {
            return Catalog.games.first { $0.slug.contains(input) || input.contains($0.slug) }
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
