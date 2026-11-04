import Testing
import Foundation
@testable import SecondChance
import GameCatalog
import SecondChanceKit
import WrappBuilder

@Suite("Game Detection")
@MainActor
struct GameDetectorTests {
    nonisolated static let fingerprintCases: [(String, String)] = [
        ("Nancy Drew Secrets Can Kill", "secrets-can-kill"),
        ("Secret of the Scarlet Hand", "scarlet-hand"),
        ("Last Train to Blue Moon Canyon", "blue-moon"),
        ("Curse of Blackmoor Manor", "blackmoor-manor"),
        ("Secret of the Old Clock", "old-clock"),
        ("Last Train To Blue Moon Canyon", "blue-moon"),
        ("Nancy Drew: The Final Scene", "final-scene"),
        ("Nancy Drew: Message in a Haunted Mansion", "haunted-mansion"),
        ("Treasure in the Royal Tower", "royal-tower"),
        ("The Secret of Shadow Ranch", "shadow-ranch"),
        ("Curse of Blackmoor Manor (Disc 1)", "blackmoor-manor"),
        ("Legend of the Crystal Skull", "crystal-skull"),
        ("The Phantom of Venice", "phantom-of-venice"),
        ("The Haunted Carousel", "haunted-carousel"),
        ("Danger on Deception Island", "deception-island"),
        ("The Secret of the Scarlet Hand", "scarlet-hand"),
        ("Ghost Dogs of Moon Lake", "ghost-dogs"),
        ("The Captive Curse", "captive-curse"),
        ("Alibi in Ashes", "alibi-in-ashes"),
        ("Tomb of the Lost Queen", "lost-queen"),
        ("The Deadly Device", "deadly-device"),
        ("Shadow at the Water's Edge", "waters-edge"),
        ("Warnings at Waverly Academy", "waverly-academy"),
        ("Trail of the Twister", "trail-of-the-twister"),
        ("Ransom of the Seven Ships", "seven-ships"),
        ("Secrets Can Kill REMASTERED", "secrets-can-kill-remastered"),
        ("The Shattered Medallion", "shattered-medallion"),
        ("The Silent Spy", "silent-spy"),
        ("The Captive Curse CAP", "captive-curse"),
        ("Labyrinth of Lies", "labyrinth-of-lies"),
        ("Sea of Darkness", "sea-of-darkness"),
        ("Stay Tuned for Danger STFD", "stay-tuned"),
        ("The White Wolf of Icicle Creek", "white-wolf"),
        ("Danger by Design", "danger-by-design"),
    ]

    nonisolated static let codeCases: [(String, String)] = [
        ("STFD", "stay-tuned"),
        ("CAP", "captive-curse"),
        ("GTH", "thornton-hall"),
        ("SPY", "silent-spy"),
        ("MED", "shattered-medallion"),
        ("LIE", "labyrinth-of-lies"),
        ("SEA", "sea-of-darkness"),
    ]

    nonisolated static let unknownCases = [
        "Random Game Title",
        "Not a Nancy Drew Game",
        "123456",
        "",
    ]

    nonisolated static let caseVariations = [
        "SECRET OF THE SCARLET HAND",
        "secret of the scarlet hand",
        "Secret Of The Scarlet Hand",
        "sEcReT oF tHe ScArLeT hAnD",
    ]

    nonisolated static let partialCases = [
        ("Nancy Drew: Secret of the Scarlet Hand (Disc 1)", "scarlet-hand"),
        ("Last Train to Blue Moon Canyon - Her Interactive", "blue-moon"),
        ("The Curse of Blackmoor Manor Game", "blackmoor-manor"),
    ]

    // Test fingerprint to game slug mapping
    @Test("Detect game from fingerprint", arguments: fingerprintCases)
    func detectFromFingerprint(fingerprint: String, expectedSlug: String) {
        let detector = GameDetector.shared
        let slug = detector.getGameSlugFromFingerprint(fingerprint)
        #expect(slug == expectedSlug, "Expected '\(fingerprint)' to match '\(expectedSlug)' but got '\(slug)'")
    }

    // Test alternate game codes
    @Test("Detect game from alternate codes", arguments: codeCases)
    func detectFromAlternateCodes(code: String, expectedSlug: String) {
        let detector = GameDetector.shared
        let slug = detector.getGameSlugFromFingerprint(code)
        #expect(slug == expectedSlug, "Expected code '\(code)' to match '\(expectedSlug)' but got '\(slug)'")
    }

    // Test that unknown fingerprints return "unknown"
    @Test("Unknown fingerprints return unknown", arguments: unknownCases)
    func unknownFingerprints(fingerprint: String) {
        let detector = GameDetector.shared
        let slug = detector.getGameSlugFromFingerprint(fingerprint)
        #expect(slug == "unknown", "Expected unknown fingerprint '\(fingerprint)' to return 'unknown' but got '\(slug)'")
    }

    // Test case insensitivity
    @Test("Fingerprint matching is case insensitive")
    func caseInsensitivity() {
        let detector = GameDetector.shared

        for variation in Self.caseVariations {
            let slug = detector.getGameSlugFromFingerprint(variation)
            #expect(slug == "scarlet-hand", "Case insensitive match failed for '\(variation)'")
        }
    }

    // Test partial matching (with extra text)
    @Test("Fingerprint with extra text still matches")
    func partialMatching() {
        let detector = GameDetector.shared

        for (fingerprint, expectedSlug) in Self.partialCases {
            let slug = detector.getGameSlugFromFingerprint(fingerprint)
            #expect(slug == expectedSlug, "Partial match failed for '\(fingerprint)'")
        }
    }
}

@Suite("Game Detection - the catalogue")
@MainActor
struct GameDetectorCatalogueTests {
    @Test("Every game in the catalogue is recognised by its own title")
    func everyTitle() {
        for game in GameInfoProvider.shared.allGames() where game.id != GameInfo.unknownGame.id {
            #expect(GameDetector.shared.getGameSlugFromFingerprint("Nancy Drew: \(game.title)") == game.id,
                    "\(game.title) isn't recognised")
        }
    }

    /// The longest match wins, so a fingerprint naming Remastered wins over
    /// Secrets Can Kill, whose title it contains. Before bundles, any title
    /// containing another's won, however the other matched: "Nancy Drew SCK
    /// Secrets Can Kill" was Remastered by its alias. Now it is Secrets Can
    /// Kill, the longer match; Remastered's disc names itself in full.
    @Test("Of two matches, the longer wins")
    func mostSpecific() {
        let detector = GameDetector.shared
        #expect(detector.getGameSlugFromFingerprint("Nancy Drew Secrets Can Kill Remastered Nancy Drew SCK") == "secrets-can-kill-remastered")
        #expect(detector.getGameSlugFromFingerprint("Nancy Drew SCK") == "secrets-can-kill-remastered")
        #expect(detector.getGameSlugFromFingerprint("Nancy Drew SCK Secrets Can Kill") == "secrets-can-kill")
        #expect(detector.getGameSlugFromFingerprint("nothing like a game") == GameInfo.unknownGame.id)
    }

    @Test("A tie is unrecognised, so the person is asked")
    func tieIsAsked() async {
        let detector = GameDetector(index: DetectionIndex(rules: [
            .init(bundleID: "nancy-drew/one", matcher: .text("twin")),
            .init(bundleID: "nancy-drew/two", matcher: .text("pair")),
        ], programs: []))
        #expect(detector.getGameSlugFromFingerprint("twin pair") == GameInfo.unknownGame.id)
        #expect(detector.getGameSlugFromFingerprint("twin") == "one")
    }

    @Test("The shipped bundles' index and GameCatalog's agree on every title, alias and code")
    func shippedIndexIsTheCatalogues() {
        let catalogue = GameDetector(index: GameDetector.catalogueIndex(GameInfoProvider.shared.allGames()))
        for game in GameInfoProvider.shared.allGames() where game.id != GameInfo.unknownGame.id {
            for name in [game.title] + game.detectionAliases + game.detectionCodes {
                #expect(GameDetector.shared.getGameSlugFromFingerprint(name) == catalogue.getGameSlugFromFingerprint(name), "\(name)")
            }
        }
    }
}

/// Validation F1: the bundles' matchers give the slugs `GameDetector` gave
/// before bundles, on every case above and every installer here.
@Suite("Game Detection - the same as before bundles")
@MainActor
struct GameDetectorBeforeBundlesTests {
    /// Every fingerprint the tests above use, every title, alias and code
    /// in the catalogue, and each with "Nancy Drew: " in front.
    nonisolated static let fingerprints: [String] = {
        let games = GameInfoProvider.shared.allGames().filter { $0.id != GameInfo.unknownGame.id }
        let names = games.flatMap { [$0.title] + $0.detectionAliases + $0.detectionCodes }
        return GameDetectorTests.fingerprintCases.map(\.0) + GameDetectorTests.codeCases.map(\.0)
            + GameDetectorTests.unknownCases + GameDetectorTests.caseVariations + GameDetectorTests.partialCases.map(\.0)
            + names + names.map { "Nancy Drew: \($0)" }
    }()

    @Test("Every fingerprint gives the slug it gave before", arguments: fingerprints)
    func sameSlug(_ fingerprint: String) {
        #expect(GameDetector.shared.getGameSlugFromFingerprint(fingerprint) == BeforeBundles.slug(forFingerprint: fingerprint))
    }

    @Test("Every disc image in installers/ gives the slug it gave before",
          .enabled(if: !BeforeBundles.discImages.isEmpty, "no disc images in installers/"))
    func sameSlugForEveryDisc() async throws {
        let mounter = ISOMounter()
        for image in BeforeBundles.discImages {
            let folder = try await mounter.mount(image)
            let source = try await GameDetector.shared.discSource(folder)
            let before = BeforeBundles.slug(forFingerprint: source.fingerprint)
            let now = await Blocking.run { GameDetector.shippedIndex.detect(source) }
            let slug: String = if case .recognised(let match) = now { GameDetector.slug(of: match.bundleID) } else { GameInfo.unknownGame.id }
            let game = image.deletingLastPathComponent().lastPathComponent
            // A program beyond Nancy Drew (one with a `program` id) came after
            // bundles: before them, its disc could only be unknown.
            let cameBefore = GameInfoProvider.shared.allGames().first { $0.id == game }?.program == nil
            if cameBefore {
                #expect(slug == before, "\(game)/\(image.lastPathComponent): \(now), before \(before)")
            }
            if image.lastPathComponent == "disk-1.iso" {
                #expect(slug == game, "\(game)'s first disc is \(slug)")
            }
            await mounter.unmountAll()
        }
    }

    @Test("Every Her Interactive Windows download in installers/ gives the slug it gave before",
          .enabled(if: !BeforeBundles.herInstallers.isEmpty, "no Her downloads in installers/"))
    func sameSlugForEveryHerDownload() async throws {
        for installer in BeforeBundles.herInstallers {
            let embedded = try await Blocking.run { try GameDetector.embeddedInstallerSignals(in: installer) }
            let product = await Blocking.run { WindowsExecutable(contentsOf: installer)?.versionStrings["ProductName"] }
            let name = installer.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            let fingerprint = ([name] + [product].compactMap { $0 } + embedded).joined(separator: " ")
            let game = installer.deletingLastPathComponent().lastPathComponent
            let slug = try await GameDetector.shared.detectGame(fromHerInstaller: installer)
            #expect(slug == BeforeBundles.slug(forFingerprint: fingerprint), "\(game)/\(installer.lastPathComponent)")
            #expect(slug == game)
        }
    }
}

/// How `GameDetector` matched a fingerprint before bundles, kept as it was
/// to compare with: the first game in the catalogue whose title (less a
/// leading "The") or alias is in the fingerprint, case aside, or whose code
/// is a word in it, unless another matching game's title contains its title.
nonisolated enum BeforeBundles {
    static func slug(forFingerprint fingerprint: String, among games: [GameInfo] = GameInfoProvider.shared.allGames()) -> String {
        let padded = " \(fingerprint) "
        let lowercased = padded.lowercased()
        let matched = games.filter { game in
            guard game.id != GameInfo.unknownGame.id else { return false }
            let title = game.title.lowercased()
            let names = [title.hasPrefix("the ") ? String(title.dropFirst(4)) : title] + game.detectionAliases.map { $0.lowercased() }
            return names.contains { lowercased.contains($0) } || game.detectionCodes.contains { padded.contains(" \($0) ") }
        }
        let mostSpecific = matched.first { game in
            !matched.contains { $0.id != game.id && $0.title.lowercased().contains(game.title.lowercased()) }
        }
        return mostSpecific?.id ?? GameInfo.unknownGame.id
    }

    /// Every `installers/<slug>/disk-N.iso`.
    static let discImages: [URL] = GameInfoProvider.shared.allGames().flatMap { game in
        (1...4).compactMap { InstallerPaths.diskISO(for: game, diskNumber: $0) }
    }

    /// Every `installers/<slug>/her-download*.exe`.
    static let herInstallers: [URL] = GameInfoProvider.shared.allGames().flatMap { game in
        InstallerPaths.herDownloads(for: game).filter { $0.pathExtension.lowercased() == "exe" }
    }
}

@Suite("Game Detection - Fixtures")
@MainActor
struct GameDetectorFixtureTests {

    @Test("Detect game from the mock disc in TestFixtures")
    func detectFromMockDisk() async throws {
        let mockDiskPath = TestPaths.repoRoot.appendingPathComponent("TestFixtures/scarlet-hand-disk")
        try #require(FileManager.default.fileExists(atPath: mockDiskPath.path), "TestFixtures/scarlet-hand-disk is committed")

        let detector = GameDetector.shared
        let gameSlug = try await detector.detectGame(fromDisk: mockDiskPath)

        #expect(gameSlug == "scarlet-hand")
    }
}
