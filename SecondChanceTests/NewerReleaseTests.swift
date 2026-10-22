//
//  NewerReleaseTests.swift
//  SecondChanceTests
//
//  Reading the newest release from the appcast, for a failed launch's
//  suggestion to update Second Chance.

import Foundation
import Testing
@testable import SecondChance

@Suite("Newer release")
struct NewerReleaseTests {
    @Test("Reads the versions Sparkle 2 writes as elements of the item")
    func readsElementVersions() {
        let appcast = """
        <?xml version="1.0" standalone="yes"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <title>Second Chance</title>
                <item>
                    <title>0.6.0</title>
                    <sparkle:version>264</sparkle:version>
                    <sparkle:shortVersionString>0.6.0</sparkle:shortVersionString>
                    <description sparkle:format="markdown"><![CDATA[### New]]></description>
                    <enclosure url="https://example.com/a.zip" length="1" type="application/octet-stream"/>
                </item>
            </channel>
        </rss>
        """
        #expect(NewerRelease.latestRelease(inAppcast: Data(appcast.utf8)) == ReleaseVersion(shortVersion: "0.6.0", build: 264))
    }

    @Test("Reads versions on the enclosure, and takes the newest item by build")
    func readsEnclosureVersionsAndPicksNewest() {
        let appcast = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
            <item><enclosure url="a" sparkle:version="100" sparkle:shortVersionString="0.4.0"/></item>
            <item><enclosure url="b" sparkle:version="300" sparkle:shortVersionString="0.7.0"/></item>
            <item><enclosure url="c" sparkle:version="200" sparkle:shortVersionString="0.5.0"/></item>
        </channel></rss>
        """
        #expect(NewerRelease.latestRelease(inAppcast: Data(appcast.utf8)) == ReleaseVersion(shortVersion: "0.7.0", build: 300))
    }

    @Test("An appcast with no release, or not XML, gives none")
    func noRelease() {
        #expect(NewerRelease.latestRelease(inAppcast: Data("<rss><channel></channel></rss>".utf8)) == nil)
        #expect(NewerRelease.latestRelease(inAppcast: Data("Not Found".utf8)) == nil)
    }

    @Test("The running version comes from the bundle's version keys")
    func runningVersion() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.6.0", "CFBundleVersion": "264"]
        #expect(NewerRelease.runningVersion(info) == ReleaseVersion(shortVersion: "0.6.0", build: 264))
        #expect(NewerRelease.runningVersion(["CFBundleShortVersionString": "1.0", "CFBundleVersion": "dev"]) == nil)
    }

    @Test("Off in a Debug build unless SECOND_CHANCE_UPDATES says otherwise")
    func disabledReason() {
        #expect(NewerRelease.disabledReason(environment: [:], isDebugBuild: false) == nil)
        #expect(NewerRelease.disabledReason(environment: [:], isDebugBuild: true) != nil)
        #expect(NewerRelease.disabledReason(environment: ["SECOND_CHANCE_UPDATES": "1"], isDebugBuild: true) == nil)
        #expect(NewerRelease.disabledReason(environment: ["SECOND_CHANCE_UPDATES": "0"], isDebugBuild: false) != nil)
    }
}
