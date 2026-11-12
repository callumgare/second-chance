import Foundation
import Testing
@testable import IconLabKit

// The catalog's pure parts: normalising, merging, ranking, labels, .env, robots.txt, the dHash, and each source's
// parser against a small recorded answer (Fixtures/).

func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent(name)
    return try Data(contentsOf: url)
}

func fixtureJSON(_ name: String) throws -> Any { try JSONSerialization.jsonObject(with: try fixture(name)) }

func hit(_ source: String, _ id: String, _ title: String, year: Int? = nil, platforms: [String] = [], developer: String? = nil,
         ids: [String: String] = [:], kind: String? = nil) -> ProgramHit {
    var h = ProgramHit(source: source, sourceId: id, title: title)
    h.year = year; h.platforms = platforms; h.developer = developer; h.ids = ids; h.kind = kind
    return h
}

@Suite struct TitleTests {
    @Test func normalises() {
        #expect(Titles.normalise("The Logical Journey of the Zoombinis™") == "logical journey of the zoombinis")
        #expect(Titles.normalise("Myst III: Exile") == "myst 3 exile")
        #expect(Titles.normalise("Zoombinis: Mountain Rescue (2001)") == "zoombinis mountain rescue")
        #expect(Titles.normalise("Pokémon & Friends") == "pokemon and friends")
        #expect(Titles.normalise("Nancy Drew®: Secrets Can Kill") == "nancy drew secrets can kill")
    }

    @Test func bases() {
        #expect(Titles.base("Myst: Masterpiece Edition") == "myst")
        #expect(Titles.base("SkiFree 1.04") == "skifree")
        #expect(Titles.base("Myst 3") == "myst 3")
        #expect(Titles.base("The Oregon Trail Deluxe") == "oregon trail")
        #expect(Titles.base("Kid Pix for Windows") == "kid pix")
    }

    @Test func cores() {
        #expect(Titles.core("Kid Pix 1.0 for DOS") == "kid pix")
        #expect(Titles.core("Logical Journey of the Zoombinis Deluxe") == "logical journey of the zoombinis deluxe")
        #expect(Titles.core("Kid Pix 2") == "kid pix 2")
    }

    @Test func variants() {
        let v = Titles.variants("Nancy Drew: Secrets Can Kill")
        #expect(v.contains("secrets can kill"))
        #expect(v.contains("nancy drew secrets can kill"))
        // word order doesn't matter in the word-set form
        #expect(!Titles.variants("Zoombinis Logical Journey").isDisjoint(with: Titles.variants("Logical Journey of the Zoombinis")))
        #expect(Titles.variants("Zoombinis: Mountain Rescue").isDisjoint(with: Titles.variants("Zoombinis")))
    }

    @Test func similarityOrders() {
        let q = "myst"
        let exact = Titles.similarity(q, "Myst"), edition = Titles.similarity(q, "Myst: Masterpiece Edition")
        let sequel = Titles.similarity(q, "Myst III: Exile"), other = Titles.similarity(q, "Riven")
        #expect(exact == 1)
        #expect(exact > edition && edition > sequel && sequel > other)
        #expect(other == 0)
        #expect(Titles.similarity("secrets can kill", "Nancy Drew: Secrets Can Kill") > 0.85)
    }
}

@Suite struct PlatformTests {
    @Test func normalises() {
        #expect(Platforms.normalise("MS-DOS") == "DOS")
        #expect(Platforms.normalise("Windows 3.X") == "Windows 3.x")
        #expect(Platforms.normalise("PC (Microsoft Windows)") == "Windows")
        #expect(Platforms.normalise("Microsoft Windows") == "Windows")
        #expect(Platforms.normalise("Apple Mac OS") == "Mac OS")
        #expect(Platforms.normalise("Classic Mac OS") == "Mac OS")
        #expect(Platforms.normalise("macOS") == "Mac OS X")
        #expect(Platforms.normalise("PC") == "PC")
        #expect(Platforms.normalise("PC Win3.xx") == "Windows 3.x")
        #expect(Platforms.normalise("PC Dos") == "DOS")
        #expect(Platforms.normalise(["Windows", "MS-DOS", "Windows", "Mac"]) == ["DOS", "Windows", "Mac OS"])
        #expect(Platforms.family("Windows 3.x") == Platforms.family("DOS"))
        #expect(Platforms.family("Mac OS") != Platforms.family("Windows"))
    }

    @Test func companies() {
        #expect(Companies.agree("Cyan", "Cyan Worlds, Inc."))
        #expect(Companies.conflict("Cyan Worlds", "Presto Studios"))
        #expect(!Companies.conflict("Brøderbund Software", nil))
        #expect(!Companies.conflict("Broderbund", "Brøderbund Software, Inc."))
    }
}

@Suite struct LabelTests {
    @Test(arguments: [
        ("Box - Front", "box-front"), ("Box - Back", "box-back"), ("Box - Spine", "box-spine"), ("Box - 3D", "box-front"),
        ("Disc", "disc"), ("Clear Logo", "logo"), ("Screenshot - Game Title", "title-screen"), ("Screenshot - Gameplay", "screenshot"),
        ("Banner", "banner"), ("Icon", "icon"), ("Fanart - Background", "art"), ("box-2D", "box-front"), ("box-2D-back", "box-back"),
        ("support-2D", "disc"), ("wheel-hd", "logo"), ("sstitle", "title-screen"), ("manuel", "manual"), ("grid", "box-front"),
        ("hero", "art"), ("LogicalJourneyOfTheZoombinisCover.png", "box-front"), ("Myst_CD_label.jpg", "disc"),
        ("Zoombinis manual page 3.jpg", "manual"), ("Myst logo.svg", "logo"), ("Myst title screen.png", "title-screen"),
        ("random.jpg", "other"),
    ])
    func maps(_ label: String, _ kind: String) {
        #expect(MediaLabels.kind(label) == kind)
        #expect(MediaKind.all.contains(MediaLabels.kind(label)))
    }
}

@Suite struct CatalogEnvTests {
    @Test func parses() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("iconlab-env-\(UUID().uuidString)")
        try """
        # a comment
        ICONLAB_TEST_A=plain
        ICONLAB_TEST_B = "quoted value"
        ICONLAB_TEST_C='single'
        ICONLAB_TEST_EMPTY=
        not a line
        ICONLAB_TEST_EQ=a=b
        """.write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        let env = Env(file: f)
        #expect(env["ICONLAB_TEST_A"] == "plain")
        #expect(env["ICONLAB_TEST_B"] == "quoted value")
        #expect(env["ICONLAB_TEST_C"] == "single")
        #expect(env["ICONLAB_TEST_EMPTY"] == nil)
        #expect(env["ICONLAB_TEST_EQ"] == "a=b")
        #expect(env["ICONLAB_TEST_MISSING"] == nil)
    }

    @Test func missingKeysSayWhich() async {
        let ctx = SourceContext(http: HTTP(cacheDir: FileManager.default.temporaryDirectory.appendingPathComponent("iconlab-http-test")),
                                env: Env(file: nil), dataDir: FileManager.default.temporaryDirectory, jobs: Jobs())
        let info = await IGDBSource(ctx).info
        #expect(info.state == .needsKey)
        #expect(info.note?.contains("IGDB_CLIENT_ID") == true)
        #expect(await BraveSource(ctx).info.state == .needsKey)
    }
}

@Suite struct MergeTests {
    @Test func sharedIdsMerge() {
        let r = Merger.merge([
            hit("wikidata", "Q645427", "SkiFree", year: 1991, ids: ["launchbox": "123", "wikipedia": "SkiFree"]),
            hit("launchbox", "123", "SkiFree", year: 1991, platforms: ["Windows 3.x"]),
            hit("wikipedia", "SkiFree", "SkiFree", year: 1991, ids: ["wikidata": "Q645427"]),
        ])
        #expect(r.count == 1)
        #expect(r[0].ids["wikidata"] == "Q645427")
        #expect(r[0].ids["launchbox"] == "123")
        #expect(r[0].mergeReasons.contains { $0.contains("Wikidata") || $0.contains("Wikipedia") || $0.contains("LaunchBox") })
        #expect(r[0].key == "wikidata:Q645427")
    }

    @Test func idsComeThroughAThirdSource() {
        // PCGamingWiki says the Steam id; Steam's own hit has it: one program
        let r = Merger.merge([
            hit("pcgamingwiki", "Myst", "Myst", year: 1993, ids: ["steam": "63610"]),
            hit("steam", "63610", "Myst: Masterpiece Edition"),
        ])
        #expect(r.count == 1)
    }

    @Test func sameSourceNeverMerges() {
        // two LaunchBox games for Windows (an original and its remaster), both linking the same Wikipedia page
        let r = Merger.merge([
            hit("launchbox", "1", "Nancy Drew: Secrets Can Kill", year: 1998, platforms: ["Windows"], ids: ["wikipedia": "Nancy Drew: Secrets Can Kill"]),
            hit("launchbox", "2", "Nancy Drew: Secrets Can Kill", year: 1999, platforms: ["Windows"], ids: ["wikipedia": "Nancy Drew: Secrets Can Kill"]),
        ])
        #expect(r.count == 2)
    }

    @Test func perPlatformEntriesJoin() {
        // LaunchBox lists Myst once for Windows and once for Mac: the same program
        let r = Merger.merge([
            hit("launchbox", "10", "Myst", year: 1993, platforms: ["Mac OS"], developer: "Cyan"),
            hit("launchbox", "11", "Myst", year: 1995, platforms: ["Windows"], developer: "Cyan"),
        ])
        #expect(r.count == 1)
        #expect(Set(IDSpace.split(r[0].ids["launchbox"])) == ["10", "11"])
    }

    @Test func reissueStaysApart() {
        let r = Merger.merge([
            hit("wikidata", "Q1", "Nancy Drew: Secrets Can Kill", year: 1998, ids: ["igdb-slug": "nancy-drew-secrets-can-kill"]),
            hit("lutris", "nancy-drew-secrets-can-kill", "Nancy Drew: Secrets Can Kill", year: 1998,
                ids: ["igdb-slug": "nancy-drew-secrets-can-kill", "steam": "42210"]),
            hit("steam", "42210", "Nancy Drew: Secrets Can Kill REMASTERED"),
        ])
        #expect(r.count == 2)
        #expect(r.contains { $0.hits.contains { $0.source == "steam" } && !$0.hits.contains { $0.source == "wikidata" } })
    }

    @Test func fuzzyMerge() {
        let r = Merger.merge([
            hit("launchbox", "1", "Logical Journey of the Zoombinis", year: 1996, platforms: ["Windows"], developer: "TERC"),
            hit("thegamesdb", "2", "The Logical Journey of the Zoombinis", year: 1997, platforms: ["PC"]),
            hit("internetarchive", "lj", "Logical Journey Of The Zoombinis (1996)", year: 2018),
            hit("internetarchive", "lj2", "Logical Journey of the Zoombinis 1.0 for DOS"),
        ])
        #expect(r.count == 1)
        #expect(r[0].year == 1996)
        #expect(r[0].mergeReasons.count == 3)
    }

    @Test func fuzzyNeedsYearAndDeveloper() {
        // years too far apart
        #expect(Merger.merge([hit("launchbox", "1", "Myst", year: 1993, platforms: ["Mac OS"]), hit("gog", "2", "Myst", year: 2021, platforms: ["Windows"])]).count == 2)
        // a conflicting developer
        #expect(Merger.merge([hit("launchbox", "1", "Doom", year: 1993, platforms: ["DOS"], developer: "id Software"),
                              hit("gog", "2", "Doom", year: 1993, platforms: ["DOS"], developer: "Bethesda Game Studios")]).count == 2)
        // a sequel isn't the same title
        #expect(Merger.merge([hit("launchbox", "1", "Zoombinis", year: 2001), hit("gog", "2", "Zoombinis: Mountain Rescue", year: 2001)]).count == 2)
        // a store entry without a date doesn't join a dated program by title alone
        #expect(Merger.merge([hit("wikidata", "Q1", "Myst", year: 1993), hit("steam", "1", "Myst")]).count == 2)
    }

    @Test func archiveItemsGather() {
        let r = Merger.merge([
            hit("wikidata", "Q1", "SkiFree", year: 1991),
            hit("internetarchive", "a", "SkiFree"),
            hit("internetarchive", "b", "SkiFree (1991)(Microsoft)"),
        ])
        #expect(r.count == 1)
        #expect(IDSpace.split(r[0].ids["internetarchive"]).count == 2)
    }

    @Test func collapsesASourcesDuplicates() {
        let c = Merger.collapse([hit("thegamesdb", "6700", "Myst", year: 1993, platforms: ["PC"]), hit("thegamesdb", "118531", "Myst", year: 1993, platforms: ["PC"])])
        #expect(c.count == 1)
        #expect(c[0].ids["thegamesdb"] == "6700,118531")
    }
}

@Suite struct RankTests {
    @Test func ordersByFitAndAgreement() throws {
        let hits = [
            hit("wikidata", "Q1", "Myst", year: 1993, platforms: ["Mac OS", "Windows"], developer: "Cyan"),
            hit("launchbox", "1", "Myst", year: 1993, platforms: ["Mac OS"], developer: "Cyan"),
            hit("wikipedia", "Myst", "Myst", year: 1993, ids: ["wikidata": "Q1"]),
            hit("wikidata", "Q2", "Myst", year: 2021, platforms: ["Windows"], developer: "Cyan Worlds"),
            hit("wikidata", "Q3", "Myst III: Exile", year: 2001, platforms: ["Windows"]),
            hit("internetarchive", "x", "Myst demo"),
            hit("wikidata", "Q4", "Riven", year: 1997),
        ]
        let r = Catalog.results(hits, query: "myst")
        #expect(r.first?.key == "wikidata:Q1")
        #expect(r.first { $0.key == "wikidata:Q2" }?.kind == "remake")
        #expect(r.first { $0.title == "Myst demo" }?.kind == "demo")
        #expect(!r.contains { $0.title == "Riven" })   // shares no word with the query
        let order = r.map(\.key)
        let q1 = try #require(order.firstIndex(of: "wikidata:Q1")), q2 = try #require(order.firstIndex(of: "wikidata:Q2"))
        #expect(q1 < q2)
        #expect(try #require(r.first).links["discmaster"] != nil)
        #expect(r.allSatisfy { (0...100).contains($0.score) })
    }
}

@Suite struct RobotsTests {
    @Test func readsTheStarGroup() {
        let rules = Robots.parse("""
        User-agent: Googlebot
        Disallow: /

        User-Agent: *
        Disallow: /search/*
        Disallow: /download.php
        Allow: /search/ok
        Crawl-Delay: 10
        """)
        #expect(Robots.allows(rules, path: "/game/zoombinis-3ei"))
        #expect(!Robots.allows(rules, path: "/search/zoombinis"))
        #expect(!Robots.allows(rules, path: "/download.php?id=4"))
        #expect(Robots.allows(rules, path: "/search/ok"))
        #expect(!Robots.allows(Robots.parse("User-agent: *\nDisallow: /"), path: "/anything"))
        #expect(Robots.allows(Robots.parse(""), path: "/anything"))
    }
}

@Suite struct DHashTests {
    func picture(_ shift: Int) -> Bitmap {
        var b = Bitmap(width: 120, height: 160)
        for y in 0..<160 {
            for x in 0..<120 {
                let i = b.index(x, y)
                let v = UInt8(((x + shift) * 7 + y * 3) % 256)
                b.pixels[i] = v; b.pixels[i + 1] = UInt8((x * y + shift) % 256); b.pixels[i + 2] = 255 - v; b.pixels[i + 3] = 255
            }
        }
        return b
    }

    @Test func sameArtAtAnotherSize() {
        let a = picture(0), b = a.resized(width: 60, height: 80)
        let ha = DHash.hash(a), hb = DHash.hash(b)
        #expect(DHash.same((ha, 0.75), (hb, 0.75)))
        #expect(!DHash.same((ha, 0.75), (hb, 1.5)))     // a different shape isn't the same art
        let c = picture(60)
        #expect(DHash.distance(ha, DHash.hash(c)) > 6)
    }
}

@Suite struct ParserTests {
    @Test func wikipedia() throws {
        let hits = WikipediaSource.parseSearch(try fixtureJSON("wikipedia-search-myst.json"))
        #expect(hits.first?.title == "Myst")
        #expect(hits.first?.year == 1993)
        #expect(hits.first?.ids["wikidata"] == "Q6497116")
        #expect(!hits.contains { $0.title.contains("Kristi") })        // a person
        #expect(!hits.contains { $0.title == "Myst (series)" })         // a series
        #expect(!hits.contains { $0.title == "Cyan Worlds" })           // a developer
    }

    @Test func wikidata() throws {
        let hits = WikidataSource.parseDetails(try fixtureJSON("wikidata-details.json"),
                                               order: ["Q2364982", "Q124075943", "Q4049240", "Q63116084", "Q6404529"])
        let lj = try #require(hits.first { $0.sourceId == "Q2364982" })
        #expect(lj.year == 1996)
        #expect(lj.platforms.contains("Mac OS") && lj.platforms.contains("Windows"))
        #expect(lj.developer == "Broderbund")
        #expect(lj.ids["mobygames"] == "16801")
        #expect(IDSpace.split(lj.ids["igdb-slug"]).count == 2)
        #expect(lj.ids["wikipedia"] == "Logical Journey of the Zoombinis")
        #expect(lj.kind == "game")
        #expect(hits.first { $0.sourceId == "Q6404529" }?.kind == "software")
    }

    @Test func lutris() throws {
        let json = try #require(try fixtureJSON("lutris-zoombinis.json") as? [String: Any])
        let hits = try #require(json["results"] as? [[String: Any]]).compactMap(LutrisSource.parseGame)
        #expect(hits.count == 2)
        #expect(hits[0].year == 1996)
        #expect(hits[0].ids["igdb-slug"] == "logical-journey-of-the-zoombinis")
        #expect(hits[1].ids["steam"] == "397430")
        #expect(hits[1].platforms.contains("Mac OS"))
    }

    @Test func steam() throws {
        let hits = SteamSource.parseSearch(try fixtureJSON("steam-zoombinis.json"))
        #expect(hits.first?.sourceId == "397430")
        #expect(hits.first?.platforms == ["Windows", "Mac OS X"])
    }

    @Test func gog() throws {
        let products = try #require((try fixtureJSON("gog-myst.json") as? [String: Any])?["products"] as? [[String: Any]])
        let hits = products.compactMap(GOGSource.parseProduct)
        let me = try #require(hits.first { $0.sourceId == "1207658818" })
        #expect(me.title == "Myst: Masterpiece Edition")
        #expect(me.year == 1999)
        #expect(me.ids["gog-slug"] == "game/myst_masterpiece_edition")
        #expect(me.developer == "Cyan Worlds")
    }

    @Test func archive() throws {
        let hits = InternetArchiveSource.parseSearch(try fixtureJSON("archive-search-zoombinis.json"))
        #expect(hits.count == 5)
        #expect(hits.contains { $0.sourceId == "logical-journey-of-the-zoombinis" && $0.year == 1996 })
        let metadata = try #require(try fixtureJSON("archive-metadata-zoombinis.json") as? [String: Any])
        let files = InternetArchiveSource.parseFiles(metadata, item: "logical-journey-of-the-zoombinis")
        let cover = try #require(files.first { $0.url.hasSuffix("LogicalJourneyOfTheZoombinisCover.png") })
        #expect(cover.kind == "box-front")
        #expect(cover.thumbUrl?.hasSuffix("LogicalJourneyOfTheZoombinisCover_thumb.jpg") == true)
        #expect(files.allSatisfy { !$0.url.contains("_thumb") })
        #expect(files.first?.kind != "other")   // named scans first
    }

    @Test func pcgamingwiki() throws {
        let hits = PCGamingWikiSource.parseSearch(try fixtureJSON("pcgw-search-skifree.json"))
        let ski = try #require(hits.first { $0.title == "SkiFree" })
        #expect(ski.year == 1991)
        #expect(ski.developer != nil)
        #expect(ski.platforms.contains("Windows 3.x") || ski.platforms.contains("Windows"))
        #expect(ski.ids["wikipedia"] == "SkiFree")
    }

    @Test func winworld() throws {
        let html = String(decoding: try fixture("winworld-hypercard.html"), as: UTF8.self)
        let h = try #require(WinWorldSource.parseProduct(html, slug: "hypercard"))
        #expect(h.title == "HyperCard")
        #expect(h.developer == "Apple")
        #expect(h.year == 1988)
        #expect(h.platforms == ["Mac OS"])
        #expect(h.kind == "software")
        #expect(h.thumb?.contains("HyperCard%20-%20About.png") == true)
    }

    @Test func macintoshRepository() throws {
        let html = String(decoding: try fixture("macrepo-myst.html"), as: UTF8.self)
        let media = MacintoshRepositorySource.parsePage(html, page: "https://www.macintoshrepository.org/4937-myst")
        #expect(media.count == 8)
        #expect(media[0].sourceLabel == "Front Cover")
        #expect(media[0].kind == "box-front")
        #expect(media[1].kind == "box-back")
        #expect(MacintoshRepositorySource.year(html) == 1993)
    }

    @Test func screenScraperRedactsCredentials() {
        let u = "https://neoclone.screenscraper.fr/api2/mediaJeu.php?devid=me&devpassword=secret&softname=x&ssid=u&sspassword=p&systemeid=135&jeuid=3&media=box-2D(us)"
        let r = ScreenScraperSource.redact(u)
        #expect(!r.contains("secret") && !r.contains("sspassword"))
        #expect(r.contains("jeuid=3"))
    }

    @Test func urlsEncodeEverything() {
        let u = URL.make("https://archive.org/advancedsearch.php", [("q", "title:(nancy AND drew) AND é"), ("fl[]", "identifier")])
        #expect(u.absoluteString.contains("fl%5B%5D=identifier"))
        #expect(u.absoluteString.contains("%C3%A9"))
    }

    @Test func idSpaces() {
        #expect(IDSpace.normalise("wikipedia", "Logical_Journey_of_the_Zoombinis") == "Logical Journey of the Zoombinis")
        #expect(IDSpace.normalise("gog-slug", "myst_masterpiece_edition") == "game/myst_masterpiece_edition")
        #expect(IDSpace.link("macintoshrepository", "4937") == "https://www.macintoshrepository.org/4937-_")
        #expect(WikidataSource.articleIRI("Nancy Drew: Secrets Can Kill") == "https://en.wikipedia.org/wiki/Nancy_Drew:_Secrets_Can_Kill")
        #expect(firstYear("1993 video game") == 1993)
        #expect(firstYear("released 12345") == nil)
    }
}

/// Which search result a program already opened belongs to.
@Suite struct OpenedProgramLinks {
    let result = Merger.merge([hit("wikidata", "Q1", "Ingenious", year: 1995, ids: ["wikidata": "Q1"])])[0]

    @Test func aProgramWithNoIdsIsItsTitlesResult() {
        #expect(Catalog.overlap(Store.ProgramInfo(slug: "ingenious", title: "Ingenious"), result) > 0)
        #expect(Catalog.overlap(Store.ProgramInfo(slug: "other", title: "Ingenious II"), result) == 0)
    }

    @Test func idsOutrankATitle() {
        var withIds = Store.ProgramInfo(slug: "ingenious-1995", title: "Something Else")
        withIds.ids = ["wikidata": "Q1"]
        #expect(Catalog.overlap(withIds, result) > Catalog.overlap(Store.ProgramInfo(slug: "ingenious", title: "Ingenious"), result))
    }

    @Test func aTitleSharedByManyIsTheHostsProgram() {
        var ours = Merger.merge([hit("wikidata", "Q9", "Ingenious", year: 1997, ids: ["wikidata": "Q9"])])[0]
        ours.bundleId = "ingenious-consortium/ingenious"
        let p = Store.ProgramInfo(slug: "ingenious", title: "Ingenious")
        #expect(Catalog.bestMatch(p, [result, ours]) == 1)
        #expect(Catalog.bestMatch(p, [result]) == 0)
    }

    @Test func aProgramWithIdsIsntMatchedByTitle() {
        var p = Store.ProgramInfo(slug: "ingenious", title: "Ingenious")
        p.ids = ["wikidata": "Q2"]
        #expect(Catalog.overlap(p, result) == 0)
    }
}
