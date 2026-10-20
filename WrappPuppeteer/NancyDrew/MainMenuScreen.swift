//
//  MainMenuScreen.swift
//  WrappPuppeteer
//
//  Finding what the scenario clicks on a Nancy Drew game's screen: the Exit
//  button on the main menu, and the Her Interactive logo on the splash.

import Foundation
import AppKit
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.MainMenuScreen")

/// Points of interest found in a game screenshot, in screenshot pixels with a
/// top-left origin.
struct MainMenuAnalysis {
    /// "Exit Game" or "Quit" text, or the quit button matched by image
    var quitButton: CGRect?
    /// "interactive" text — the Her Interactive logo, which needs a click to
    /// get past the splash to the menu
    var interactiveLogo: CGRect?
}

enum MainMenuScreen {
    private static let exitTexts = ["Exit Game", "Quit"]
    private static let logoText = "interactive"

    /// Games whose Exit is a graphic rather than text are matched against
    /// assets/quit-button.png. Across the series that button is red and sits
    /// in the bottom-right corner, at roughly the same size relative to the
    /// game's screen, so the search is narrowed to match. (The scenario's
    /// screenshots are of the game's window alone.)
    static let quitButtonMatchOptions = TemplateMatchOptions(
        searchRegion: CGRect(x: 2.0 / 3.0, y: 5.0 / 6.0, width: 1.0 / 3.0, height: 1.0 / 6.0),
        templateHeightFraction: 0.0662,
        scaleVariations: [1.0],
        grayscale: .redEmphasis
    )

    /// Analyse a screenshot. OCR and the template match run in parallel.
    /// Usable standalone against a saved screenshot (`--analyze`).
    static func analyze(screenshotPath: String, app: NSRunningApplication? = nil) -> MainMenuAnalysis {
        let quitButtonImagePath = resolveQuitButtonImagePath()

        let dispatchGroup = DispatchGroup()
        var foundTexts: [String: CGRect] = [:]
        var quitButtonLocation: CGRect?

        dispatchGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            foundTexts = TextRecognizer.findText(exitTexts + [logoText], in: screenshotPath, loggingWhileFrontmost: app)
            dispatchGroup.leave()
        }

        dispatchGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            quitButtonLocation = TemplateMatcher.findImage(quitButtonImagePath, in: screenshotPath, options: quitButtonMatchOptions)
            dispatchGroup.leave()
        }

        dispatchGroup.wait()

        let result = MainMenuAnalysis(
            quitButton: exitTexts.lazy.compactMap { foundTexts[$0] }.first ?? quitButtonLocation,
            interactiveLogo: foundTexts[logoText]
        )

        logger.notice("Screen analysis results:")
        if let r = result.quitButton { logger.notice("  Quit button: \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))") }
        if let r = result.interactiveLogo { logger.notice("  Interactive logo: \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))") }
        if result.quitButton == nil && result.interactiveLogo == nil {
            logger.notice("  (nothing found)")
        }

        return result
    }

    /// The quit-button template from the app bundle, or from the source tree
    /// when running a dev build that hasn't copied it.
    private static func resolveQuitButtonImagePath() -> String {
        if let bundled = Bundle.main.path(forResource: "quit-button", ofType: "png") {
            return bundled
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("WrappPuppeteer/NancyDrew/assets/quit-button.png").path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        fatalError("quit-button.png not found in bundle or source tree. Add it to the WrappPuppeteer target's Copy Bundle Resources build phase.")
    }
}
