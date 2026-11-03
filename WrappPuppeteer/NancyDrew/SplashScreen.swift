//
//  SplashScreen.swift
//  WrappPuppeteer
//
//  Recognising a whole screen from its `screen` needles — the Her
//  Interactive logo, a game's title card, an intro — any of which a click
//  skips. The references are cut from recordings of the games starting
//  (`--record`, docs/testing.md#splash-screens): the nancy-drew module's
//  `needles/splash/` for those many games share, each game's bundle's
//  `tests/needles/splash/` for its own.

import Foundation
import CoreGraphics
import ImageIO
import Logging
import PuppeteerCore
import WrappBuilder

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.SplashScreen")

struct SplashScreen {
    let needle: Needle
    let fingerprint: ImageFingerprint

    /// What the reference shows, for logs: its file's name.
    var name: String { needle.name }

    /// How far a capture's fingerprint may be from a reference's to be that
    /// screen. Tuned against recordings of every game, where a game's
    /// splashes and its menu sit well either side of it.
    static let matchDistance: Float = 0.08

    /// A capture recognised as one of the screens.
    struct Match {
        let screen: SplashScreen
        let distance: Float
        /// Where the picture is in the capture, as fractions of it with a
        /// top-left origin — clear of any bars around it.
        let contentRect: CGRect

        /// Where to click, as fractions of the capture: the needle's click
        /// point in the picture.
        var clickFraction: CGPoint { screen.needle.clickPoint(in: contentRect) }
    }

    /// The `screen` needles tagged `tag`, fingerprinted.
    static func screens(tagged tag: String, in needles: NeedleLibrary) -> [SplashScreen] {
        needles.tagged(tag).filter { $0.spec.kind == .screen }.compactMap { needle in
            // Saved already trimmed (--make-splash-reference)
            guard let image = needle.image, let fingerprint = ImageFingerprint(imageAt: image.path, trimmingMargins: false) else {
                logger.warning("⚠️  Screen needle \(needle.id) is blank or unreadable; ignoring it")
                return nil
            }
            return SplashScreen(needle: needle, fingerprint: fingerprint)
        }.sorted { $0.name < $1.name }
    }

    /// The screen `fingerprint` is, if any.
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
}
