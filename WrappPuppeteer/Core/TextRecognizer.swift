//
//  TextRecognizer.swift
//  WrappPuppeteer
//
//  OCR over a screenshot with Apple's Vision framework.

import Foundation
import AppKit
import CoreGraphics
import Vision
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.TextRecognizer")

enum TextRecognizer {
    /// Find each of `searchTexts` (case-insensitive substring match) in the
    /// image. Returns the rect of the first line containing each text found, in
    /// image pixels with a top-left origin; texts not found are absent.
    ///
    /// Every recognised line is logged, unless `app` is given and isn't
    /// frontmost — that keeps the log quiet once the target has gone away.
    static func findText(_ searchTexts: [String], in imagePath: String, loggingWhileFrontmost app: NSRunningApplication? = nil) -> [String: CGRect] {
        guard let image = NSImage(contentsOfFile: imagePath),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            logger.error("⚠️  Failed to load image for OCR")
            return [:]
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let observations: [VNRecognizedTextObservation]
        do {
            try handler.perform([request])
            observations = request.results ?? []
        } catch {
            logger.error("⚠️  OCR failed: \(error)")
            return [:]
        }

        let shouldLogDetected = app.map { NSWorkspace.shared.frontmostApplication?.processIdentifier == $0.processIdentifier } ?? true
        if shouldLogDetected {
            logger.notice("  → Detected text on screen:")
            for (index, observation) in observations.enumerated() {
                guard let candidate = observation.topCandidates(1).first else { continue }
                logger.notice("     [\(index)] '\(candidate.string)' (confidence: \(String(format: "%.2f", candidate.confidence)))")
            }
        }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        var foundTexts: [String: CGRect] = [:]

        for searchText in searchTexts {
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first,
                      candidate.string.lowercased().contains(searchText.lowercased()) else { continue }

                // Vision's bounding box is normalised with a bottom-left origin
                let box = observation.boundingBox
                let rect = CGRect(
                    x: box.minX * imageSize.width,
                    y: (1 - box.maxY) * imageSize.height,
                    width: box.width * imageSize.width,
                    height: box.height * imageSize.height
                )

                logger.notice("  ✓ Found '\(searchText)' - matched text: '\(candidate.string)' at (\(Int(rect.midX)), \(Int(rect.midY)))")
                saveAnnotatedScreenshot(imagePath: imagePath, rect: rect, label: searchText)

                foundTexts[searchText] = rect
                break
            }
        }

        return foundTexts
    }

    /// Box the found text on a copy of the screenshot (`<name>-annotated.png`).
    private static func saveAnnotatedScreenshot(imagePath: String, rect: CGRect, label: String) {
        DebugImage.annotate(imagePath, suffix: "annotated") { imageHeight in
            let flipped = DebugImage.flip(rect, imageHeight: imageHeight)
            DebugImage.box(flipped, stroke: .red, lineWidth: 4)
            NSColor.green.setFill()
            NSBezierPath(ovalIn: CGRect(x: flipped.midX - 5, y: flipped.midY - 5, width: 10, height: 10)).fill()
            DebugImage.label(label, at: CGPoint(x: flipped.minX, y: flipped.maxY + 5), size: 16, color: .yellow)
        }
    }
}
