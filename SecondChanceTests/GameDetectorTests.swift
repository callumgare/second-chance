import Testing
import Foundation
@testable import SecondChance

@Suite("Game Detection")
struct GameDetectorTests {
    
    // Test fingerprint to game slug mapping
    @Test("Detect game from fingerprint", arguments: [
        ("Nancy Drew Secrets Can Kill", "secrets-can-kill-remastered"),
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
    ])
    func detectFromFingerprint(fingerprint: String, expectedSlug: String) {
        let detector = GameDetector.shared
        let slug = detector.getGameSlugFromFingerprint(fingerprint)
        #expect(slug == expectedSlug, "Expected '\(fingerprint)' to match '\(expectedSlug)' but got '\(slug ?? "nil")'")
    }
    
    // Test alternate game codes
    @Test("Detect game from alternate codes", arguments: [
        ("STFD", "stay-tuned"),
        ("CAP", "captive-curse"),
        ("GTH", "thornton-hall"),
        ("SPY", "silent-spy"),
        ("MED", "shattered-medallion"),
        ("LIE", "labyrinth-of-lies"),
        ("SEA", "sea-of-darkness"),
    ])
    func detectFromAlternateCodes(code: String, expectedSlug: String) {
        let detector = GameDetector.shared
        let slug = detector.getGameSlugFromFingerprint(code)
        #expect(slug == expectedSlug, "Expected code '\(code)' to match '\(expectedSlug)' but got '\(slug ?? "nil")'")
    }
    
    // Test that unknown fingerprints return "unknown"
    @Test("Unknown fingerprints return unknown", arguments: [
        "Random Game Title",
        "Not a Nancy Drew Game",
        "123456",
        "",
    ])
    func unknownFingerprints(fingerprint: String) {
        let detector = GameDetector.shared
        let slug = detector.getGameSlugFromFingerprint(fingerprint)
        #expect(slug == "unknown", "Expected unknown fingerprint '\(fingerprint)' to return 'unknown' but got '\(slug)'")
    }
    
    // Test case insensitivity
    @Test("Fingerprint matching is case insensitive")
    func caseInsensitivity() {
        let detector = GameDetector.shared
        
        let variations = [
            "SECRET OF THE SCARLET HAND",
            "secret of the scarlet hand",
            "Secret Of The Scarlet Hand",
            "sEcReT oF tHe ScArLeT hAnD"
        ]
        
        for variation in variations {
            let slug = detector.getGameSlugFromFingerprint(variation)
            #expect(slug == "scarlet-hand", "Case insensitive match failed for '\(variation)'")
        }
    }
    
    // Test partial matching (with extra text)
    @Test("Fingerprint with extra text still matches")
    func partialMatching() {
        let detector = GameDetector.shared
        
        let fingerprints = [
            "Nancy Drew: Secret of the Scarlet Hand (Disc 1)",
            "Last Train to Blue Moon Canyon - Her Interactive",
            "The Curse of Blackmoor Manor Game",
        ]
        
        let expected = ["scarlet-hand", "blue-moon", "blackmoor-manor"]
        
        for (fingerprint, expectedSlug) in zip(fingerprints, expected) {
            let slug = detector.getGameSlugFromFingerprint(fingerprint)
            #expect(slug == expectedSlug, "Partial match failed for '\(fingerprint)'")
        }
    }
}

@Suite("Game Detection - Integration Tests")
struct GameDetectorIntegrationTests {
    
    // These tests require mock disk structures
    // They will be skipped if the test fixtures don't exist
    
    @Test("Detect game from mock disk with setup.exe")
    func detectFromMockDiskWithSetupExe() async throws {
        let testFixturesPath = URL(fileURLWithPath: "/Users/callumgare/repos/second-chance/SecondChance/TestFixtures")
        let mockDiskPath = testFixturesPath.appendingPathComponent("scarlet-hand-disk")
        
        guard FileManager.default.fileExists(atPath: mockDiskPath.path) else {
            // Skip test if fixture not found
            return
        }
        
        let detector = GameDetector.shared
        let gameSlug = try await detector.detectGame(fromDisk: mockDiskPath)
        
        #expect(gameSlug == "scarlet-hand")
    }
}
