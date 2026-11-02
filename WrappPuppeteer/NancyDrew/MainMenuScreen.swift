//
//  MainMenuScreen.swift
//  WrappPuppeteer
//
//  Finding what the scenario clicks on a Nancy Drew game's screen: the Exit
//  button on the main menu, and the Her Interactive logo on the splash.

import Foundation
import AppKit
import Logging
import PuppeteerCore
import Synchronization

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
    private nonisolated static let exitTexts = ["Exit Game", "Quit"]
    private nonisolated static let logoText = "interactive"

    /// Games whose Exit is a graphic rather than text are matched against
    /// assets/quit-button.png. Across the series that button is red and sits
    /// in the bottom-right corner, at roughly the same size relative to the
    /// game's screen, so the search is narrowed to match. (The scenario's
    /// screenshots are of the game's window alone.)
    nonisolated static let quitButtonMatchOptions = TemplateMatchOptions(
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
        let found = Mutex<[String: CGRect]>([:])
        let matched = Mutex<CGRect?>(nil)

        dispatchGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let texts = TextRecognizer.findText(exitTexts + [logoText], in: screenshotPath, loggingWhileFrontmost: app)
            found.withLock { $0 = texts }
            dispatchGroup.leave()
        }

        dispatchGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let location = TemplateMatcher.findImage(quitButtonImagePath, in: screenshotPath, options: quitButtonMatchOptions)
            matched.withLock { $0 = location }
            dispatchGroup.leave()
        }

        dispatchGroup.wait()
        let foundTexts = found.withLock { $0 }
        let quitButtonLocation = matched.withLock { $0 }

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

    /// The quit-button template: the nancy-drew module's
    /// `needles/quit-button.png` (`NancyDrewNeedles`).
    private static func resolveQuitButtonImagePath() -> String {
        guard let file = NancyDrewNeedles.file("quit-button.png") else {
            fatalError("quit-button.png not found in the nancy-drew module, in the source tree or WrappPuppeteer's bundle.")
        }
        return file.path
    }
}
