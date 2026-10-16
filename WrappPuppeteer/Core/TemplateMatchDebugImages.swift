//
//  TemplateMatchDebugImages.swift
//  WrappPuppeteer
//
//  Visualisations written by TemplateMatcher when FIND_IMAGE_EXTRA_DEBUGGING
//  is set. Inputs are in screenshot pixels with a top-left origin; values
//  relative to the search crop come with the crop's offset.

import Foundation
import AppKit
import CoreGraphics

enum TemplateMatchDebugImages {
    static func saveTemplate(templatePath: String, screenshotPath: String) {
        guard let template = NSImage(contentsOfFile: templatePath),
              let cgImage = template.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        DebugImage.saveImage(cgImage, besides: screenshotPath, suffix: "template")
    }

    static func searchRegion(screenshotPath: String, searchStartX: Int, searchStartY: Int, searchEndX: Int, searchEndY: Int) {
        DebugImage.annotate(screenshotPath, suffix: "search-region") { imageHeight in
            let rect = DebugImage.flip(
                CGRect(x: searchStartX, y: searchStartY, width: searchEndX - searchStartX, height: searchEndY - searchStartY),
                imageHeight: imageHeight
            )
            DebugImage.box(rect, stroke: .systemRed, fill: NSColor.systemRed.withAlphaComponent(0.3))
            DebugImage.label("Search Region", at: CGPoint(x: rect.minX + 5, y: rect.maxY - 25))
        }
    }

    /// Correlation at every coarse-pass position, blue (low) through red (high).
    static func heatmap(
        screenshotPath: String,
        scalePercent: Int,
        templateWidth: Int,
        templateHeight: Int,
        searchEndX: Int,
        searchEndY: Int,
        coarseStride: Int,
        offsetX: Int,
        offsetY: Int,
        correlationAt: (_ x: Int, _ y: Int) -> Float
    ) {
        DebugImage.annotate(screenshotPath, suffix: "heatmap-scale\(scalePercent)") { imageHeight in
            for y in Swift.stride(from: 0, to: searchEndY - templateHeight, by: coarseStride) {
                for x in Swift.stride(from: 0, to: searchEndX - templateWidth, by: coarseStride) {
                    let corr = CGFloat(correlationAt(x, y))
                    let hue: CGFloat
                    if corr < 0 {
                        hue = 0.66
                    } else if corr < 0.5 {
                        hue = 0.66 - (corr * 0.32)
                    } else if corr < 0.7 {
                        hue = 0.5 - ((corr - 0.5) * 0.85)
                    } else if corr < 0.85 {
                        hue = 0.33 - ((corr - 0.7) * 1.13)
                    } else {
                        hue = 0.16 - ((corr - 0.85) * 1.07)
                    }
                    NSColor(calibratedHue: hue, saturation: 1, brightness: 1, alpha: 0.5).setFill()
                    let cell = CGRect(x: x + offsetX, y: y + offsetY, width: templateWidth, height: templateHeight)
                    NSBezierPath(rect: DebugImage.flip(cell, imageHeight: imageHeight)).fill()
                }
            }

            DebugImage.label("Scale: \(scalePercent)% - Template: \(templateWidth)x\(templateHeight)", at: CGPoint(x: 10, y: imageHeight - 30), size: 16)

            let legend: [(label: String, hue: CGFloat)] = [("< 0", 0.66), ("0.5", 0.5), ("0.7", 0.33), ("0.85", 0.16), ("1.0", 0.0)]
            for (index, item) in legend.enumerated() {
                let rect = NSRect(x: CGFloat(10 + index * 60), y: imageHeight - 60, width: 50, height: 20)
                DebugImage.box(rect, stroke: .black, fill: NSColor(calibratedHue: item.hue, saturation: 1, brightness: 1, alpha: 0.8), lineWidth: 1)
                DebugImage.label(item.label, at: CGPoint(x: rect.minX + 5, y: rect.minY + 3), size: 10)
            }
        }
    }

    /// The top five coarse candidates at each scale.
    static func allMatches(
        screenshotPath: String,
        allScaleMatches: [(scaleIndex: Int, scale: CGFloat, matches: [(x: Int, y: Int, correlation: Float)])],
        templateSizes: [(width: Int, height: Int)],
        offsetX: Int,
        offsetY: Int
    ) {
        DebugImage.annotate(screenshotPath, suffix: "all-matches") { imageHeight in
            for scaleMatch in allScaleMatches {
                let size = templateSizes[scaleMatch.scaleIndex]
                let topMatches = scaleMatch.matches.sorted { $0.correlation > $1.correlation }.prefix(5)
                for (index, match) in topMatches.enumerated() {
                    let rect = DebugImage.flip(
                        CGRect(x: match.x + offsetX, y: match.y + offsetY, width: size.width, height: size.height),
                        imageHeight: imageHeight
                    )
                    DebugImage.box(rect, stroke: .systemBlue, fill: NSColor.systemBlue.withAlphaComponent(0.2), lineWidth: 2)
                    DebugImage.label(
                        "S\(Int(scaleMatch.scale * 100))%-#\(index + 1): \(String(format: "%.2f", match.correlation))",
                        at: CGPoint(x: rect.minX + 2, y: rect.minY + 2),
                        size: 12
                    )
                }
            }
        }
    }

    static func finalMatch(screenshotPath: String, match: CGRect, correlation: Float) {
        DebugImage.annotate(screenshotPath, suffix: "final-match") { imageHeight in
            let rect = DebugImage.flip(match, imageHeight: imageHeight)
            DebugImage.box(rect, stroke: .systemGreen, fill: NSColor.systemGreen.withAlphaComponent(0.3))
            DebugImage.label("Match: \(String(format: "%.2f", correlation))", at: CGPoint(x: rect.minX + 5, y: rect.maxY + 5))
        }
    }

    /// The images compared at a single probed position (FIND_IMAGE_DEBUG_PROBE).
    static func probe(
        screenshotPath: String,
        templatePath: String,
        colorTemplate: CGImage,
        grayTemplate: UnsafePointer<UInt8>,
        grayScreenshot: UnsafePointer<UInt8>,
        screenshotWidth: Int,
        screenshotHeight: Int,
        debugX: Int,
        debugY: Int,
        debugWidth: Int,
        debugHeight: Int,
        correlation: Float,
        searchStartX: Int,
        searchStartY: Int
    ) {
        DebugImage.saveImage(colorTemplate, besides: screenshotPath, suffix: "debug-color-template")
        DebugImage.saveGray(grayTemplate, width: debugWidth, height: debugHeight, besides: screenshotPath, suffix: "debug-gray-template")
        DebugImage.saveGray(grayScreenshot, width: screenshotWidth, height: screenshotHeight, besides: screenshotPath, suffix: "debug-gray-search-region")

        var region = [UInt8](repeating: 0, count: debugWidth * debugHeight)
        for y in 0..<debugHeight {
            for x in 0..<debugWidth {
                region[y * debugWidth + x] = grayScreenshot[(debugY + y) * screenshotWidth + (debugX + x)]
            }
        }
        region.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            DebugImage.saveGray(base, width: debugWidth, height: debugHeight, besides: screenshotPath, suffix: "debug-gray-region")
        }

        let fullX = debugX + searchStartX
        let fullY = debugY + searchStartY
        DebugImage.annotate(screenshotPath, suffix: "debug-specific-position") { imageHeight in
            let rect = DebugImage.flip(CGRect(x: fullX, y: fullY, width: debugWidth, height: debugHeight), imageHeight: imageHeight)
            NSImage(contentsOfFile: templatePath)?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.5)
            let color: NSColor = correlation >= 0.85 ? .systemGreen : (correlation >= 0.7 ? .systemYellow : .systemRed)
            DebugImage.box(rect, stroke: color, lineWidth: 4)
            DebugImage.label(
                "Test Position: (\(fullX), \(fullY))  Size: \(debugWidth)x\(debugHeight)  Correlation: \(String(format: "%.4f", correlation))",
                at: CGPoint(x: rect.minX + 5, y: rect.maxY + 10)
            )
        }
    }
}
