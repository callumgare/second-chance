import Foundation

/// How likely a picture found by a general search (Wikimedia Commons, Openverse, a web image search) is about the
/// program rather than something sharing its name. Nothing is thrown away: the score ranks and folds.
///
/// Two signals. The words: the picture's title, description and categories mention the program's developer or
/// publisher, a year near its own, words that say it's a game or software; a far-off year counts against. And the
/// picture itself (in the analysis): MobileCLIP says whether it looks like game material or like a photo, a painting
/// or a page of an old book.
nonisolated public enum Relevance {
    static let gameWords: Set<String> = ["game", "games", "videogame", "videogames", "computer", "software", "cdrom", "cd", "rom",
                                         "disc", "disk", "floppy", "box", "boxart", "cover", "screenshot", "screenshots", "logo",
                                         "pc", "mac", "macintosh", "windows", "dos", "msdos", "amiga", "edutainment", "educational",
                                         "adventure", "puzzle", "interactive", "multimedia", "shareware", "freeware", "sprite", "pixel"]

    public struct Score: Codable, Sendable, Hashable {
        public var text: Double                 // 0…1, from the words
        public var reasons: [String]
    }

    /// The words' score. `specific`: it came back from the game-specific search too.
    public static func score(_ text: String, identity: ProgramIdentity, specific: Bool) -> Score {
        let words = Set(Titles.tokens(text))
        var s = 0.35
        var why: [String] = []
        if specific { s += 0.25; why.append("found by the game-specific search") }
        let makers = [identity.developer, identity.publisher].compactMap { $0 }
        for m in makers {
            let mt = Set(Titles.tokens(m)).filter { $0.count > 2 && !["inc", "ltd", "corp", "software", "games", "entertainment", "the"].contains($0) }
            if !mt.isEmpty, mt.isSubset(of: words) { s += 0.25; why.append("mentions \(m)"); break }
        }
        let hits = words.intersection(gameWords)
        if !hits.isEmpty {
            s += min(0.25, 0.1 * Double(hits.count))
            let what = hits.contains("game") || hits.contains("videogame") ? "a game" : "software or game material"
            why.append("says it's \(what) (“\(hits.sorted().prefix(3).joined(separator: "”, “"))”)")
        }
        if let y = identity.year {
            let years = text.matches(of: /\b(1[5-9]\d\d|20\d\d)\b/).compactMap { Int($0.output.1) }
            if years.contains(where: { abs($0 - y) <= 2 }) { s += 0.15; why.append("dated near \(y)") } else if let far = years.first(where: { abs($0 - y) > 6 }) {
                s -= 0.3; why.append("dated \(far), far from \(y)")
            }
        }
        let offTopic: Set<String> = ["church", "cathedral", "painting", "manuscript", "folio", "museum", "statue", "portrait", "street",
                                     "building", "monument", "bridge", "lithograph", "engraving", "map", "coat", "arms", "flag", "gun"]
        let off = words.intersection(offTopic)
        if !off.isEmpty, hits.isEmpty { s -= 0.15; why.append("sounds unrelated (“\(off.sorted().prefix(2).joined(separator: "”, “"))”)") }
        return Score(text: max(0, min(1, s)), reasons: why)
    }

    /// The prompts for the picture check: what game material looks like, and what a namesake usually is.
    public static let gamePrompts = ["the box art of a computer game", "a screenshot of a video game", "a screenshot of computer software",
                                     "a CD-ROM disc", "a video game logo", "pixel art from a computer game", "a floppy disk with a label"]
    public static let otherPrompts = ["a photograph of a building", "a photograph of people", "an old painting", "a page from an old book",
                                      "a photograph of a machine or a tool", "a landscape photograph", "a drawing in a manuscript"]
}
