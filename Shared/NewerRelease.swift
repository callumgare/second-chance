//
//  NewerRelease.swift
//  Shared
//
//  Whether a newer Second Chance has been released than the one that built
//  this wrapp: a failed launch suggests updating and setting the game up
//  again, since the fix may already be out. Read from the appcast Second
//  Chance itself updates from (docs/updates.md).

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.NewerRelease")

struct ReleaseVersion: Equatable {
    /// `CFBundleShortVersionString`, which people see.
    let shortVersion: String
    /// `CFBundleVersion`, the commit count, which orders releases as Sparkle does.
    let build: Int
}

enum NewerRelease {
    /// The wrapp's Info.plist key for the appcast's address, copied from
    /// Second Chance's `SUFeedURL` when the wrapp is built. A wrapp without
    /// it was built before the check existed, and doesn't check.
    static let feedURLKey = "SecondChanceFeedURL"

    /// The version that built this wrapp: the template's own, as
    /// `sc release` versions WrappTemplate along with the app.
    static func runningVersion(_ info: [String: Any]? = Bundle.main.infoDictionary) -> ReleaseVersion? {
        guard let shortVersion = info?["CFBundleShortVersionString"] as? String,
              let build = (info?["CFBundleVersion"] as? String).flatMap({ Int($0) }) else { return nil }
        return ReleaseVersion(shortVersion: shortVersion, build: build)
    }

    /// Why not to check, or nil to. As Second Chance's own update checks: off
    /// in a Debug build, whose version is the last release's whatever it
    /// holds, and `SECOND_CHANCE_UPDATES=1` or `0` overrides that.
    static func disabledReason(environment: [String: String], isDebugBuild: Bool) -> String? {
        if let forced = environment["SECOND_CHANCE_UPDATES"] {
            return forced == "1" ? nil : "SECOND_CHANCE_UPDATES=\(forced)"
        }
        return isDebugBuild ? "Debug build" : nil
    }

    /// The newest release the feed names, if it is newer than this wrapp's
    /// version; nil when it isn't, or when that can't be found out.
    static func check(info: [String: Any]? = Bundle.main.infoDictionary) async -> ReleaseVersion? {
        if let reason = disabledReason(environment: ProcessInfo.processInfo.environment,
                                       isDebugBuild: FailureReporter.isDebugBuild) {
            logger.debug("Not checking for a newer Second Chance: \(reason)")
            return nil
        }
        guard let feed = (info?[feedURLKey] as? String).flatMap(URL.init(string:)) else {
            logger.debug("Not checking for a newer Second Chance: this wrapp has no feed address")
            return nil
        }
        guard let running = runningVersion(info) else {
            logger.warning("Not checking for a newer Second Chance: this wrapp's version is missing")
            return nil
        }
        let request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.warning("Couldn't check for a newer Second Chance: the feed answered \(http.statusCode)")
                return nil
            }
            data = body
        } catch {
            logger.warning("Couldn't check for a newer Second Chance: \(error.localizedDescription)")
            return nil
        }
        guard let latest = latestRelease(inAppcast: data) else {
            logger.warning("Couldn't check for a newer Second Chance: the feed names no release")
            return nil
        }
        guard latest.build > running.build else {
            logger.notice("This wrapp was built by Second Chance \(running.shortVersion) (\(running.build)), the latest release")
            return nil
        }
        logger.notice("This wrapp was built by Second Chance \(running.shortVersion) (\(running.build)); \(latest.shortVersion) (\(latest.build)) is out")
        return latest
    }

    /// The newest item in a Sparkle appcast. Sparkle 2 writes the versions
    /// as elements of the item; older appcasts put them on its enclosure.
    static func latestRelease(inAppcast data: Data) -> ReleaseVersion? {
        let reader = AppcastReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        return reader.releases.max { $0.build < $1.build }
    }
}

private final class AppcastReader: NSObject, XMLParserDelegate {
    private(set) var releases: [ReleaseVersion] = []
    private var inItem = false
    private var build: String?
    private var shortVersion: String?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "item" {
            inItem = true
            build = nil
            shortVersion = nil
        } else if inItem, name == "enclosure" {
            build = build ?? attributes["sparkle:version"]
            shortVersion = shortVersion ?? attributes["sparkle:shortVersionString"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "sparkle:version" where inItem:
            build = value
        case "sparkle:shortVersionString" where inItem:
            shortVersion = value
        case "item":
            inItem = false
            if let build = build.flatMap({ Int($0) }) {
                releases.append(ReleaseVersion(shortVersion: shortVersion ?? String(build), build: build))
            }
        default:
            break
        }
        text = ""
    }
}
