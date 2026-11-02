//
//  DownloadNotice.swift
//  SecondChance
//
//  What the person is told before a free game downloads: why it's free and
//  where it comes from, in plain words, by its edition's licence.

import Foundation
import WrappBuilder

/// What is shown before a download edition downloads, and saved into its
/// app as its "Licence" file. Never says "freeware", "shareware",
/// "licence", "mirror" or "hash" (docs/program-bundles.md#download-editions).
nonisolated struct DownloadNotice: Equatable {
    let title: String
    let body: String

    init(licence: Manifest.Licence, game: String) {
        switch licence {
        case .freewareLicensed:
            title = String(localized: "\(game) is free.")
            body = String(localized: """
                Its makers have given it away and say anyone may share it. Second Chance will download it, \
                check it's the genuine file, and set it up for you.
                """)
        case .freeRelease:
            title = String(localized: "\(game) is free.")
            body = String(localized: """
                The people who made it now give it away. Second Chance will download it from their website. \
                If their website doesn't have it any more, Second Chance gets the same file from the Internet Archive, \
                a library that keeps copies of old websites. Either way, it checks it's the genuine file first.
                """)
        case .shareware:
            title = String(localized: "This is the free first part of \(game).")
            body = String(localized: """
                Its makers let anyone share it for free, as long as it isn't changed. The rest of the game was sold \
                separately. Second Chance will download the free part, from the Internet Archive if the makers' website \
                no longer has it, and check it's the genuine, unchanged file.
                """)
        case .abandonware:
            title = String(localized: "\(game) isn't sold any more.")
            body = String(localized: """
                Nobody has sold it for a long time, and its makers haven't said whether it may be shared. \
                Second Chance will download a copy kept by the Internet Archive, a library that keeps copies of old \
                software, and check it's the genuine file first.
                """)
        }
    }

    /// The "Licence" file saved into the game's app.
    func licenceFile(from: String?) -> String {
        var text = title + "\n\n" + body + "\n"
        if let from { text += "\n" + String(localized: "Where its makers say so: \(from).") + "\n" }
        return text
    }
}
