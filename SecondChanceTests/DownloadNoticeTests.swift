//
//  DownloadNoticeTests.swift
//  SecondChanceTests
//
//  What the person is told before a free game downloads.

import Foundation
import Testing
import GameCatalog
import WrappBuilder
@testable import SecondChance

@Suite("Download notice")
struct DownloadNoticeTests {
    @Test("Each kind of free game is explained in plain words",
          arguments: [Manifest.Licence.freewareLicensed, .freeRelease, .shareware, .abandonware])
    func plainWords(licence: Manifest.Licence) {
        let notice = DownloadNotice(licence: licence, game: "SkiFree")
        let text = (notice.title + " " + notice.body).lowercased()
        #expect(notice.title.contains("SkiFree"))
        for word in ["freeware", "shareware", "abandonware", "licence", "license", "mirror", "hash", "wayback"] {
            #expect(!text.contains(word), "\(licence): says \(word)")
        }
    }

    @Test func theLicenceFileSaysWherePermissionComesFrom() {
        let file = DownloadNotice(licence: .freeRelease, game: "SkiFree").licenceFile(from: "the author's website")
        #expect(file.hasPrefix("SkiFree is free."))
        #expect(file.contains("the author's website"))
    }

    @Test func theShippedDownloadEditionsIncludeSkiFree() throws {
        let editions = try ShippedBundles.downloadEditions()
        let skifree = try #require(editions.first { $0.game.programID == "freeware/skifree" })
        #expect(skifree.licence == .freeRelease)
        #expect(skifree.game.appName == "SkiFree")
        #expect(skifree.input.sha256?.count == 64)
    }
}
