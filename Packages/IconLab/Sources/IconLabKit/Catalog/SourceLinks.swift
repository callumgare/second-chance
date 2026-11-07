import Foundation
import Synchronization

/// Where a person can see a picture at its source: the page it came from when the source gave one, else a search for
/// the program there, else the source's home page. Shown in the image inspector (docs/api.md, Media.link).
nonisolated public enum SourceLinks {
    public struct Link: Codable, Sendable, Hashable {
        public var url: String
        /// "page": the page the picture came from; "search": a search for the program at the source; "home": the source.
        public var kind: String
        public var label: String      // "LaunchBox", "Wikimedia Commons"
    }

    /// Source id → its name, home page and a search URL (`{q}` is the program's title, escaped).
    static let sources: [String: (name: String, home: String, search: String?)] = [
        "wikipedia": ("Wikipedia", "https://en.wikipedia.org", "https://en.wikipedia.org/w/index.php?search={q}"),
        "commons": ("Wikimedia Commons", "https://commons.wikimedia.org", "https://commons.wikimedia.org/w/index.php?search={q}&title=Special:MediaSearch&type=image"),
        "wikidata": ("Wikidata", "https://www.wikidata.org", "https://www.wikidata.org/w/index.php?search={q}"),
        "internetarchive": ("Internet Archive", "https://archive.org", "https://archive.org/search?query={q}"),
        "launchbox": ("LaunchBox", "https://gamesdb.launchbox-app.com", "https://gamesdb.launchbox-app.com/games/results/{q}"),
        "thegamesdb": ("TheGamesDB", "https://thegamesdb.net", "https://thegamesdb.net/search.php?name={q}"),
        "openverse": ("Openverse", "https://openverse.org", "https://openverse.org/search/image?q={q}"),
        "myabandonware": ("My Abandonware", "https://www.myabandonware.com", "https://www.myabandonware.com/search/q/{q}"),
        "gog": ("GOG", "https://www.gog.com", "https://www.gog.com/en/games?query={q}"),
        "steam": ("Steam", "https://store.steampowered.com", "https://store.steampowered.com/search/?term={q}"),
        "lutris": ("Lutris", "https://lutris.net", "https://lutris.net/games?q={q}"),
        "pcgamingwiki": ("PCGamingWiki", "https://www.pcgamingwiki.com", "https://www.pcgamingwiki.com/w/index.php?search={q}"),
        "igdb": ("IGDB", "https://www.igdb.com", "https://www.igdb.com/search?q={q}"),
        "steamgriddb": ("SteamGridDB", "https://www.steamgriddb.com", "https://www.steamgriddb.com/search/grids?term={q}"),
        "screenscraper": ("ScreenScraper", "https://www.screenscraper.fr", nil),
        "mobygames": ("MobyGames", "https://www.mobygames.com", "https://www.mobygames.com/search/?q={q}"),
        "winworld": ("WinWorld", "https://winworldpc.com", "https://winworldpc.com/search?q={q}"),
        "macintoshrepository": ("Macintosh Repository", "https://www.macintoshrepository.org", nil),
        "macintoshgarden": ("Macintosh Garden", "https://macintoshgarden.org", "https://macintoshgarden.org/search/node/{q}"),
        "brave": ("Brave Search", "https://search.brave.com", "https://search.brave.com/images?q={q}"),
    ]

    /// The best link for a picture, or nil for one from the person's own files.
    public static func link(for m: MediaRecord, programTitle: String?) -> Link? {
        // the source's id: the remote's, else (pictures imported before remotes were kept) by its name
        let id = m.remote?.source ?? sources.first(where: { $0.value.name.lowercased() == m.source.lowercased() })?.key
        guard let id, let s = sources[id] else { return nil }
        if let page = m.remote?.pageUrl ?? m.sourceUrl, page.hasPrefix("http") {
            // a source whose page couldn't be told apart (LaunchBox, with several of the same name) gave its search
            return Link(url: page, kind: page.contains("/games/results/") ? "search" : "page", label: s.name)
        }
        if let t = programTitle, let search = s.search,
           let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+/?#"))) {
            return Link(url: search.replacingOccurrences(of: "{q}", with: q), kind: "search", label: s.name)
        }
        return Link(url: s.home, kind: "home", label: s.name)
    }
}

nonisolated extension Lab {
    private static let titles = Mutex<[String: String]>([:])

    /// The program's title, read once from its program.json (for the media's search links).
    func programTitle(_ slug: String) -> String? {
        if let t = Lab.titles.withLock({ $0[slug] }) { return t }
        guard let d = try? Data(contentsOf: store.dir(slug).appendingPathComponent("program.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = o["title"] as? String else { return nil }
        Lab.titles.withLock { $0[slug] = t }
        return t
    }
}
