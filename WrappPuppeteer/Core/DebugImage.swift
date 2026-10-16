//
//  DebugImage.swift
//  WrappPuppeteer
//
//  Writes annotated copies of screenshots for debugging the vision code.

import Foundation
import AppKit
import CoreGraphics
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.DebugImage")

enum DebugImage {
    /// Draw over a copy of the screenshot and save it beside the original as
    /// `<name>-<suffix>.png`. Drawing happens in screenshot *pixels* with
    /// AppKit's bottom-left origin — use `flip` for top-left rects.
    static func annotate(_ screenshotPath: String, suffix: String, draw: (_ imageHeight: CGFloat) -> Void) {
        guard let image = NSImage(contentsOfFile: screenshotPath),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: cgImage.width,
                  pixelsHigh: cgImage.height,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            logger.warning("⚠️  Could not open \(screenshotPath) for annotation")
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        draw(CGFloat(cgImage.height))
        NSGraphicsContext.restoreGraphicsState()

        save(rep, to: derivedPath(screenshotPath, suffix: suffix))
    }

    /// Save a single-channel buffer as a grayscale PNG.
    static func saveGray(_ data: UnsafePointer<UInt8>, width: Int, height: Int, besides screenshotPath: String, suffix: String) {
        guard let provider = CGDataProvider(data: Data(bytes: data, count: width * height) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return
        }
        save(NSBitmapImageRep(cgImage: cgImage), to: derivedPath(screenshotPath, suffix: suffix))
    }

    static func saveImage(_ cgImage: CGImage, besides screenshotPath: String, suffix: String) {
        save(NSBitmapImageRep(cgImage: cgImage), to: derivedPath(screenshotPath, suffix: suffix))
    }

    /// Convert a top-left-origin rect to the bottom-left origin used when drawing.
    static func flip(_ rect: CGRect, imageHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: imageHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func box(_ rect: CGRect, stroke: NSColor, fill: NSColor? = nil, lineWidth: CGFloat = 3) {
        if let fill {
            fill.setFill()
            NSBezierPath(rect: rect).fill()
        }
        stroke.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = lineWidth
        path.stroke()
    }

    /// Outlined text, legible on any background.
    static func label(_ text: String, at point: CGPoint, size: CGFloat = 14, color: NSColor = .white) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.0
        ]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    // MARK: - Private

    private static func derivedPath(_ screenshotPath: String, suffix: String) -> String {
        screenshotPath.replacingOccurrences(of: ".png", with: "-\(suffix).png")
    }

    private static func save(_ rep: NSBitmapImageRep, to path: String) {
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            logger.warning("⚠️  Could not encode debug image \(path)")
            return
        }
        do {
            try pngData.write(to: URL(fileURLWithPath: path))
            logger.notice("  💾 Saved debug image: \(path)")
        } catch {
            logger.warning("⚠️  Could not write debug image \(path): \(error)")
        }
    }
}
