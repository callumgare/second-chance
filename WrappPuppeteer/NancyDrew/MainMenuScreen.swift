//
//  MainMenuScreen.swift
//  WrappPuppeteer
//
//  Finding a scenario's `text` and `region` needles on a screenshot: the
//  Exit on a game's main menu, the Her Interactive logo before it.

import Foundation
import AppKit
import Logging
import PuppeteerCore
import Synchronization
import WrappBuilder

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.MainMenuScreen")

/// A needle found on a screenshot, in screenshot pixels with a top-left
/// origin.
struct FoundNeedle {
    let needle: Needle
    let rect: CGRect

    /// Where to click it, in the same pixels.
    var clickPoint: CGPoint { needle.clickPoint(in: rect) }
}

enum MainMenuScreen {
    /// Look for `needles` on a screenshot: every `text` needle's strings in
    /// one OCR pass, beside each `region` needle's template match. The
    /// result is one match per tag: a text needle's first, as reading the
    /// words is surer than matching a picture, in its strings' order.
    /// Usable standalone against a saved screenshot (`--analyze`).
    static func analyze(screenshotPath: String, needles: [Needle], app: NSRunningApplication? = nil) -> [String: FoundNeedle] {
        let texts = needles.filter { $0.spec.kind == .text }
        let regions = needles.filter { $0.spec.kind == .region }
        let strings = texts.flatMap { $0.spec.text?.strings ?? [] }

        let dispatchGroup = DispatchGroup()
        let read = Mutex<[String: CGRect]>([:])
        let matched = Mutex<[String: CGRect]>([:])

        if !strings.isEmpty {
            dispatchGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let found = TextRecognizer.findText(strings, in: screenshotPath, loggingWhileFrontmost: app)
                read.withLock { $0 = found }
                dispatchGroup.leave()
            }
        }
        for needle in regions {
            guard let image = needle.image else { continue }
            dispatchGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let location = TemplateMatcher.findImage(image.path, in: screenshotPath, options: matchOptions(needle))
                if let location { matched.withLock { $0[needle.id] = location } }
                dispatchGroup.leave()
            }
        }
        dispatchGroup.wait()
        let foundTexts = read.withLock { $0 }, foundRegions = matched.withLock { $0 }

        var result: [String: FoundNeedle] = [:]
        func add(_ found: FoundNeedle) {
            for tag in found.needle.spec.tags where result[tag] == nil { result[tag] = found }
        }
        for needle in texts {
            if let rect = (needle.spec.text?.strings ?? []).lazy.compactMap({ foundTexts[$0] }).first {
                add(FoundNeedle(needle: needle, rect: rect))
            }
        }
        for needle in regions {
            if let rect = foundRegions[needle.id] { add(FoundNeedle(needle: needle, rect: rect)) }
        }

        logger.notice("Screen analysis results:")
        for (tag, found) in result.sorted(by: { $0.key < $1.key }) {
            let r = found.rect
            logger.notice("  \(tag) (\(found.needle.id)): \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))")
        }
        if result.isEmpty { logger.notice("  (nothing found)") }
        return result
    }

    /// A `region` needle's search, as the template matcher takes it.
    nonisolated static func matchOptions(_ needle: Needle) -> TemplateMatchOptions {
        let region = needle.spec.region
        return TemplateMatchOptions(
            searchRegion: region?.search?.cgRect ?? CGRect(x: 0, y: 0, width: 1, height: 1),
            templateHeightFraction: region?.heightFraction.map { CGFloat($0) },
            scaleVariations: region?.scales.map { $0.map { CGFloat($0) } } ?? [1.0],
            grayscale: region?.grayscale == "red-emphasis" ? .redEmphasis : .luminance
        )
    }
}
