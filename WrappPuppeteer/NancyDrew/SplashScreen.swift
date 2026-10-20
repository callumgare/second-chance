//
//  SplashScreen.swift
//  WrappPuppeteer
//
//  Recognising the screens a Nancy Drew game shows before its main menu —
//  the Her Interactive logo, the game's title card, an intro — any of which a
//  click skips. They are reference images in assets/splash/, cut from
//  recordings of the games starting (`--record`, docs/testing.md#splash-screens):
//  `splash-<game slug>-<what it shows>.png` for one game's, and
//  `splash-any-<what it shows>.png` for those many games share, such as the
//  Her Interactive logos.

import Foundation
import CoreGraphics
import ImageIO
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.SplashScreen")

struct SplashScreen {
    /// What the reference shows: the part of its file name after the slug.
    let name: String
    let fingerprint: ImageFingerprint

    /// How far a capture's fingerprint may be from a reference's to be that
    /// screen. Tuned against recordings of every game, where a game's
    /// splashes and its menu sit well either side of it.
    static let matchDistance: Float = 0.08

    /// A capture recognised as one of a game's splash screens.
    struct Match {
        let screen: SplashScreen
        let distance: Float
        /// Where the picture is in the capture, as fractions of it with a
        /// top-left origin — clear of any bars around it.
        let contentRect: CGRect
    }

    /// The splash screens a game may show: its own and the shared ones.
    static func screens(forGame slug: String) -> [SplashScreen] {
        let prefixes = ["splash-\(slug)-", "splash-any-"]
        return referencePaths().compactMap { path in
            let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard let prefix = prefixes.first(where: { file.hasPrefix($0) }) else { return nil }
            // Saved already trimmed (--make-splash-reference)
            guard let fingerprint = ImageFingerprint(imageAt: path, trimmingMargins: false) else {
                logger.warning("⚠️  Splash reference \(file) is blank or unreadable; ignoring it")
                return nil
            }
            let name = String(file.dropFirst(prefix.count))
            return SplashScreen(name: prefix == "splash-any-" ? "any-" + name : name, fingerprint: fingerprint)
        }.sorted { $0.name < $1.name }
    }

    /// The splash screen `fingerprint` is, if any.
    static func match(_ fingerprint: ImageFingerprint, among screens: [SplashScreen]) -> Match? {
        guard let best = closest(fingerprint, among: screens), best.distance <= matchDistance else { return nil }
        return best
    }

    /// The nearest screen whatever the distance — for tuning (`--classify`).
    static func closest(_ fingerprint: ImageFingerprint, among screens: [SplashScreen]) -> Match? {
        screens
            .map { Match(screen: $0, distance: fingerprint.distance(to: $0.fingerprint), contentRect: fingerprint.contentRect) }
            .min { $0.distance < $1.distance }
    }

    /// Every splash reference: from the source tree when WrappPuppeteer runs
    /// from a build inside it, else from the app bundle. The source tree goes
    /// first because a build keeps a reference that was since deleted or
    /// renamed, and doesn't pick up one just made until it is rebuilt.
    private static func referencePaths() -> [String] {
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("WrappPuppeteer/NancyDrew/assets/splash")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: candidate.path) {
                return files.filter { $0.hasPrefix("splash-") && $0.hasSuffix(".png") }
                    .map { candidate.appendingPathComponent($0).path }
            }
        }
        return Bundle.main.paths(forResourcesOfType: "png", inDirectory: nil)
            .filter { ($0 as NSString).lastPathComponent.hasPrefix("splash-") }
    }
}
