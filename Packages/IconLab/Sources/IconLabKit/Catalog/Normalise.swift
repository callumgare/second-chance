import Foundation

// Titles, platforms, companies and media labels, each brought to one form so hits from different sources compare.

nonisolated public enum Titles {
    /// Whether two years are within one of each other; a year nobody knows fits any.
    static func yearsClose(_ a: Int?, _ b: Int?) -> Bool {
        guard let a, let b else { return true }
        return abs(a - b) <= 1
    }

    static let stopwords: Set<String> = ["the", "a", "an", "of", "and", "for", "le", "la", "les", "de", "der", "die", "das"]
    static let romans: [String: String] = ["ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10",
                                           "xi": "11", "xii": "12"]
    /// Words that name an edition rather than the program ("Myst: Masterpiece Edition", "SkiFree for Windows").
    static let editionWords: Set<String> = ["deluxe", "gold", "platinum", "edition", "special", "collectors", "collector", "masterpiece",
                                            "anniversary", "classic", "enhanced", "complete", "definitive", "cd", "rom", "cdrom",
                                            "version", "windows", "dos", "mac", "macintosh", "remastered", "remaster", "hd",
                                            "director", "directors", "cut", "jewel", "case", "budget", "re", "release", "reissue", "for", "pc"]

    /// Lowercase, ASCII-folded, punctuation as spaces, ™®© and bracketed asides dropped, "&" as "and", roman numerals as
    /// digits, a leading article dropped, spaces collapsed.
    public static func normalise(_ s: String) -> String {
        tokens(s, keepStopwords: true).joined(separator: " ")
    }

    public static func tokens(_ s: String, keepStopwords: Bool = false) -> [String] {
        var t = s
        for ch in ["™", "®", "©", "℠"] { t = t.replacingOccurrences(of: ch, with: "") }
        t = t.decomposedStringWithCompatibilityMapping.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .init(identifier: "en_US"))
        t = t.lowercased()
        for (a, b) in ["ø": "o", "æ": "ae", "œ": "oe", "ß": "ss", "ł": "l", "đ": "d", "þ": "th"] { t = t.replacingOccurrences(of: a, with: b) }
        t = t.replacingOccurrences(of: "\\([^)]*\\)|\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = t.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        var out: [String] = []
        var cur = ""
        for u in t.unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) { cur.unicodeScalars.append(u) } else if !cur.isEmpty { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        out = out.map { romans[$0] ?? $0 }
        if keepStopwords {
            if out.count > 1, ["the", "a", "an"].contains(out[0]) { out.removeFirst() }
            return out
        }
        let kept = out.filter { !stopwords.contains($0) }
        return kept.isEmpty ? out : kept
    }

    /// The title without edition words or a version at its end: "Myst: Masterpiece Edition" → "myst",
    /// "SkiFree 1.04" → "skifree" ("Myst 3" keeps its 3).
    public static func base(_ s: String) -> String {
        var toks = tokens(s, keepStopwords: true)
        func isNum(_ t: String) -> Bool { t.range(of: "^[0-9]+$", options: .regularExpression) != nil }
        while toks.count > 1 {
            let last = toks[toks.count - 1]
            if editionWords.contains(last) || last.range(of: "^v[0-9]+$", options: .regularExpression) != nil { toks.removeLast(); continue }
            if toks.count > 2, isNum(last), isNum(toks[toks.count - 2]) { toks.removeLast(2); continue }
            break
        }
        return toks.joined(separator: " ")
    }

    /// The title without a version or platform at its end ("Kid Pix 1.0 for DOS" → "kid pix"), but with its edition
    /// ("Deluxe") kept: what a yearless hit (an archive item) must match.
    public static func core(_ s: String) -> String {
        var toks = tokens(s, keepStopwords: true)
        let platformWords: Set<String> = ["for", "windows", "win", "dos", "mac", "macintosh", "pc", "cd", "rom", "cdrom", "version", "95", "31", "3"]
        func isNum(_ t: String) -> Bool { t.range(of: "^v?[0-9]+[a-z]{0,2}$", options: .regularExpression) != nil }
        while toks.count > 1 {
            let last = toks[toks.count - 1]
            if platformWords.contains(last) && toks.count > 2 { toks.removeLast(); continue }
            if last.hasPrefix("v"), isNum(last) { toks.removeLast(); continue }
            if toks.count > 2, isNum(last), isNum(toks[toks.count - 2]) { toks.removeLast(2); continue }
            if toks.count > 2, isNum(last), platformWords.contains(toks[toks.count - 2]) { toks.removeLast(); continue }
            break
        }
        return toks.joined(separator: " ")
    }

    /// Forms of a title that count as "the same title": the whole, its base, the part after a series prefix
    /// ("Nancy Drew: Secrets Can Kill" → "secrets can kill"), and its word set in any order.
    public static func variants(_ s: String) -> Set<String> {
        var v: Set<String> = [normalise(s), base(s)]
        for sep in [":", " - ", " – "] where s.contains(sep) {
            let after = s.components(separatedBy: sep).dropFirst().joined(separator: " ")
            if tokens(after).count >= 2 { v.insert(normalise(after)) }
        }
        v.insert("#" + Set(tokens(s)).sorted().joined(separator: " "))
        v.remove("")
        v.remove("#")
        return v
    }

    /// How well a title answers a query, 0…1: exact ≫ prefix ≫ all words present ≫ some.
    public static func similarity(_ query: String, _ title: String) -> Double {
        let q = normalise(query), t = normalise(title)
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        if q == t { return 1 }
        if base(title) == q || base(query) == t { return 0.9 }
        let qt = Set(tokens(query)), tt = Set(tokens(title))
        if qt == tt { return 0.93 }
        if t.hasPrefix(q + " ") { return 0.85 - min(0.15, Double(tt.count - qt.count) * 0.03) }
        // the query is the part after a series name ("secrets can kill")
        if variants(title).contains(q) { return 0.88 }
        let common = qt.intersection(tt)
        guard !common.isEmpty else {
            // partial word (prefix) matches: "zoombini" vs "zoombinis"
            let partial = qt.filter { w in tt.contains { $0.hasPrefix(w) || w.hasPrefix($0) } }
            return partial.isEmpty ? 0 : 0.3 * Double(partial.count) / Double(qt.count)
        }
        let recall = Double(common.count) / Double(qt.count)
        let precision = Double(common.count) / Double(tt.count)
        if recall == 1 { return 0.6 + 0.2 * precision }
        return 0.5 * recall * (0.5 + 0.5 * precision)
    }

    /// A URL- and file-safe slug.
    public static func slug(_ s: String) -> String { normalise(s).replacingOccurrences(of: " ", with: "-") }
}

nonisolated public enum Platforms {
    /// Brings a source's platform name to ours: "Windows", "Windows 3.x", "DOS", "PC" (DOS or Windows, unknown),
    /// "Mac OS" (classic), "Mac OS X" (and macOS), "Linux", "Apple II", "Amiga", … or nil for ones we ignore.
    public static func normalise(_ raw: String) -> String? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s.contains("3.1") || s.contains("3.x") || s.contains("win3") || s.contains("windows 3") || s == "pc win3.xx" { return "Windows 3.x" }
        if s.contains("dos") && !s.contains("windows") { return "DOS" }
        if s.contains("windows") || s == "win" || s == "win32" || s.contains("pc win") || s == "pc (microsoft windows)" { return "Windows" }
        if s == "pc" || s == "ibm pc" || s == "ibm pc compatible" || s == "pc compatible" { return "PC" }
        if s.contains("classic mac") || s == "apple mac os" || s == "mac os" || s == "macos classic" || s.hasPrefix("mac os 7")
            || s.hasPrefix("mac os 8") || s.hasPrefix("mac os 9") || s == "system 7" || s == "macintosh" || s == "mac" || s == "mac os (classic)"
            || s == "macos (classic)" || s == "apple macintosh" { return "Mac OS" }
        if s.contains("os x") || s.contains("osx") || s == "macos" || s.hasPrefix("macos ") || s.contains("mac os x") { return "Mac OS X" }
        if s.contains("linux") || s.contains("steamos") { return "Linux" }
        if s.contains("apple ii") || s.contains("apple 2") { return "Apple II" }
        if s.contains("amiga") { return "Amiga" }
        if s.contains("ios") || s.contains("iphone") || s.contains("ipad") { return "iOS" }
        if s.contains("android") { return "Android" }
        if s.contains("browser") || s.contains("web") || s.contains("flash") { return "Web" }
        // keep other systems' names, tidied (consoles turn up in some sources)
        return raw.trimmingCharacters(in: .whitespaces)
    }

    public static func normalise(_ raws: [String]) -> [String] {
        var out: [String] = []
        for r in raws { if let p = normalise(r), !out.contains(p) { out.append(p) } }
        return out.sorted { order($0) < order($1) }
    }

    static func order(_ p: String) -> Int {
        ["DOS": 0, "Windows 3.x": 1, "Windows": 2, "PC": 3, "Mac OS": 4, "Mac OS X": 5, "Linux": 6][p] ?? 10
    }

    /// The family a platform belongs to: PCs, Macs, or itself.
    public static func family(_ p: String) -> String {
        switch p {
        case "DOS", "Windows 3.x", "Windows", "PC": return "pc"
        case "Mac OS", "Mac OS X": return "mac"
        default: return p.lowercased()
        }
    }

    /// The era the app is for: DOS, Windows 3.x / 9x and classic Mac.
    public static func isOldDesktop(_ p: String) -> Bool { ["DOS", "Windows 3.x", "Windows", "PC", "Mac OS"].contains(p) }
}

nonisolated public enum Companies {
    static let noise: Set<String> = ["inc", "ltd", "llc", "co", "corp", "corporation", "company", "software", "interactive", "entertainment",
                                     "games", "game", "studios", "studio", "productions", "publishing", "multimedia", "gmbh", "sa", "plc",
                                     "the", "and", "of", "media", "digital", "group", "international", "llp", "limited", "kk"]

    public static func tokens(_ s: String?) -> Set<String> {
        guard let s else { return [] }
        return Set(Titles.tokens(s, keepStopwords: true).filter { !noise.contains($0) && $0.count > 1 })
    }

    /// Two developers conflict when both are known and share no word ("Cyan" vs "Cyan Worlds" agree).
    public static func conflict(_ a: String?, _ b: String?) -> Bool {
        let x = tokens(a), y = tokens(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x.isDisjoint(with: y)
    }

    public static func agree(_ a: String?, _ b: String?) -> Bool {
        let x = tokens(a), y = tokens(b)
        return !x.isEmpty && !y.isEmpty && !x.isDisjoint(with: y)
    }
}

/// Maps sources' own labels to `MediaKind`.
nonisolated public enum MediaLabels {
    /// The kind a source's label names exactly, or nil when the label only hints (the analysis decides then).
    public static func exactKind(_ label: String) -> String? {
        exact[label.lowercased().trimmingCharacters(in: .whitespaces)]
    }

    public static func kind(_ label: String) -> String {
        let l = label.lowercased()
        // LaunchBox's types first (exact), then words anywhere (file names, captions, other sources' types)
        if let k = exact[l] { return k }
        return fuzzy(l)
    }

    static let exact: [String: String] = [
            "box - front": "box-front", "box - front - reconstructed": "box-front", "fanart - box - front": "art", "box - 3d": "box-front",
            "box - back": "box-back", "box - back - reconstructed": "box-back", "fanart - box - back": "art",
            "box - spine": "box-spine", "box - full": "art", "disc": "disc", "fanart - disc": "art", "cart - front": "media", "cart - back": "media",
            "clear logo": "logo", "screenshot - game title": "title-screen", "screenshot - gameplay": "screenshot",
            "screenshot - game select": "screenshot", "screenshot - high scores": "screenshot", "screenshot - game over": "screenshot",
            "fanart - background": "art", "banner": "banner", "steam banner": "banner", "icon": "icon", "square": "art",
            "advertisement flyer - front": "art", "advertisement flyer - back": "art", "arcade - marquee": "banner",
            "amazon poster": "art", "epic games poster": "art", "gog poster": "art", "origin poster": "art", "uplay thumbnail": "art",
            "steam poster": "art", "poster": "art", "manual": "manual",
            // ScreenScraper
            "box-2d": "box-front", "box-2d-back": "box-back", "box-2d-side": "box-spine", "box-3d": "box-front", "box-scan": "box-front",
            "support-2d": "disc", "support-scan": "disc", "wheel": "logo", "wheel-hd": "logo", "wheel-carbon": "logo", "wheel-steel": "logo",
            "sstitle": "title-screen", "ss": "screenshot", "fanart": "art", "flyer": "art", "marquee": "banner", "manuel": "manual",
            "steamgrid": "banner", "screenmarquee": "banner", "mixrbv1": "other", "mixrbv2": "other", "bezel-16-9": "other",
            // SteamGridDB, IGDB, Steam, GOG
            "grid": "box-front", "hero": "art", "logo": "logo", "cover": "box-front", "artwork": "art", "screenshot": "screenshot",
            "library capsule": "box-front", "library hero": "art", "header": "banner", "capsule": "banner", "background": "art",
            // TheGamesDB
            "boxart front": "box-front", "boxart back": "box-back", "clearlogo": "logo", "titlescreen": "title-screen",
        ]

    static func fuzzy(_ l: String) -> String {
        func has(_ words: String...) -> Bool { words.contains { l.contains($0) } }
        if has("spine", "side") && has("box", "cover", "case") { return "box-spine" }
        if has("back") && has("box", "cover", "case", "boxart", "inlay", "rear") { return "box-back" }
        if has("box", "front", "cover", "boxart", "packag", "jewel", "case", "inlay", "sleeve") && !has("back") { return "box-front" }
        if has("disc", "disk", "cd-rom", "cdrom", "cd label", "_cd", " cd", "cd.", "floppy", "media", "support", "label") { return "disc" }
        if has("logo", "wordmark", "wheel") { return "logo" }
        if has("icon", "favicon") { return "icon" }
        if has("title screen", "titlescreen", "title_screen", "title-screen", "sstitle", "splash") { return "title-screen" }
        if has("manual", "guide", "booklet", "reference card", "refcard") { return "manual" }
        if has("banner", "header", "marquee") { return "banner" }
        if has("screenshot", "screen shot", "gameplay", "ingame", "in-game", "in game", "scrn", "snap") { return "screenshot" }
        if has("art", "poster", "flyer", "advert", "wallpaper", "hero", "promo") { return "art" }
        return "other"
    }
}

/// Every id namespace a hit can carry, with its name, its Wikidata property, and how to link to it.
nonisolated public enum IDSpace {
    public struct Space: Sendable {
        public var key: String
        public var name: String
        public var wikidata: String?        // property, e.g. "P7785"
        public var link: String?            // "$1" is the id
    }

    public static let all: [Space] = [
        .init(key: "wikidata", name: "Wikidata", wikidata: nil, link: "https://www.wikidata.org/wiki/$1"),
        .init(key: "wikipedia", name: "Wikipedia", wikidata: nil, link: "https://en.wikipedia.org/wiki/$1"),
        // no link: the data's DatabaseID isn't the website's page number (LaunchBox.pageURL finds the page)
        .init(key: "launchbox", name: "LaunchBox", wikidata: "P7785", link: nil),
        .init(key: "thegamesdb", name: "TheGamesDB", wikidata: "P7622", link: "https://thegamesdb.net/game.php?id=$1"),
        .init(key: "igdb", name: "IGDB", wikidata: "P9043", link: nil),
        .init(key: "igdb-slug", name: "IGDB", wikidata: "P5794", link: "https://www.igdb.com/games/$1"),
        .init(key: "steamgriddb", name: "SteamGridDB", wikidata: "P12561", link: "https://www.steamgriddb.com/game/$1"),
        .init(key: "screenscraper", name: "ScreenScraper", wikidata: "P7756", link: "https://www.screenscraper.fr/gameinfos.php?gameid=$1"),
        .init(key: "pcgamingwiki", name: "PCGamingWiki", wikidata: "P6337", link: "https://www.pcgamingwiki.com/wiki/$1"),
        .init(key: "lutris", name: "Lutris", wikidata: "P7597", link: "https://lutris.net/games/$1/"),
        .init(key: "steam", name: "Steam", wikidata: "P1733", link: "https://store.steampowered.com/app/$1/"),
        .init(key: "gog", name: "GOG", wikidata: "P12727", link: nil),
        .init(key: "gog-slug", name: "GOG", wikidata: "P2725", link: "https://www.gog.com/$1"),
        .init(key: "internetarchive", name: "Internet Archive", wikidata: "P724", link: "https://archive.org/details/$1"),
        .init(key: "macintoshrepository", name: "Macintosh Repository", wikidata: "P7812", link: "https://www.macintoshrepository.org/$1-_"),
        .init(key: "macintoshgarden", name: "Macintosh Garden", wikidata: "P7811", link: "https://macintoshgarden.org/games/$1"),
        .init(key: "myabandonware", name: "My Abandonware", wikidata: "P12652", link: "https://www.myabandonware.com/game/--$1"),
        .init(key: "winworld", name: "WinWorld", wikidata: nil, link: "https://winworldpc.com/product/$1"),
        .init(key: "mobygames", name: "MobyGames", wikidata: "P11688", link: "https://www.mobygames.com/game/$1/"),
        .init(key: "mobygames-slug", name: "MobyGames", wikidata: "P1933", link: "https://www.mobygames.com/game/$1"),
        .init(key: "gamefaqs", name: "GameFAQs", wikidata: "P4769", link: "https://gamefaqs.gamespot.com/-/$1-"),
        .init(key: "winehq", name: "Wine AppDB", wikidata: "P600", link: "https://appdb.winehq.org/objectManager.php?sClass=application&iId=$1"),
        .init(key: "abandonia", name: "Abandonia", wikidata: "P4962", link: "http://www.abandonia.com/games/$1"),
        .init(key: "oldgamesru", name: "Old-Games.ru", wikidata: "P10394", link: "https://old-games.ru/game/$1.html"),
        .init(key: "abandonwarefrance", name: "Abandonware France", wikidata: "P12267", link: "https://www.abandonware-france.org/ltf_abandon/ltf_jeu.php?id=$1"),
        .init(key: "commonscat", name: "Wikimedia Commons", wikidata: "P373", link: "https://commons.wikimedia.org/wiki/Category:$1"),
    ]

    public static let byKey: [String: Space] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    /// Namespaces that only describe, never identify (several programs can share a Commons category).
    public static let notIdentifying: Set<String> = ["commonscat"]

    /// Id values compared as one form: Wikipedia titles with spaces and a capital first letter, slugs lowercase.
    public static func normalise(_ key: String, _ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespaces)
        switch key {
        case "wikipedia", "pcgamingwiki":
            v = (v.removingPercentEncoding ?? v).replacingOccurrences(of: "_", with: " ")
            if let f = v.first { v = f.uppercased() + v.dropFirst() }
        case "igdb-slug", "lutris", "myabandonware", "winworld", "macintoshgarden", "mobygames-slug", "internetarchive-lc":
            v = v.lowercased()
        case "gog-slug":
            v = v.lowercased()
            if !v.contains("/") { v = "game/" + v }
            if v.hasPrefix("en/") { v.removeFirst(3) }
        default: break
        }
        return v
    }

    /// A link to the program at a namespace's site.
    public static func link(_ key: String, _ value: String) -> String? {
        guard let f = byKey[key]?.link else { return nil }
        let v: String
        switch key {
        case "wikipedia", "pcgamingwiki", "commonscat": v = value.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
        case "gog-slug": v = value
        default: v = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
        }
        return f.replacingOccurrences(of: "$1", with: v)
    }

    /// Several ids in one value ("123,456": LaunchBox's Windows and Mac releases).
    public static func split(_ v: String?) -> [String] {
        (v ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
