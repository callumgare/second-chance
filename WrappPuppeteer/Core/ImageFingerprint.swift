//
//  ImageFingerprint.swift
//  WrappPuppeteer
//
//  A tiny, cheap summary of a screen's picture, for telling whether a capture
//  shows a screen seen before. The near-black margins are trimmed first, so
//  the letterbox or pillarbox bars a display's shape puts around a picture
//  don't come into it: the same picture fingerprints alike in a 16:9 window,
//  a 16:10 one or one below a notch.

import Foundation
import CoreGraphics
import ImageIO
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.ImageFingerprint")

struct ImageFingerprint {
    /// The fingerprint's grid, in cells.
    static let width = 24
    static let height = 18

    /// RGB per cell, 0…1, row by row from the top.
    let values: [Float]
    /// Where the picture sits in the image it came from, as fractions of that
    /// image with a top-left origin — the part left once the dark margins are
    /// trimmed.
    let contentRect: CGRect

    /// Mean difference per channel, 0 (identical) … 1.
    func distance(to other: ImageFingerprint) -> Float {
        var total: Float = 0
        for index in values.indices {
            total += abs(values[index] - other.values[index])
        }
        return total / Float(values.count)
    }

    /// Nil for an image that couldn't be read, or that is dark all over — a
    /// screen not drawn yet, or between two pictures. `trimmingMargins` false
    /// takes the whole image, for one already trimmed (`content(of:width:)`):
    /// trimming again would cut further in.
    init?(imageAt path: String, trimmingMargins: Bool = true) {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            logger.warning("Couldn't read \(path)")
            return nil
        }
        self.init(image: image, trimmingMargins: trimmingMargins)
    }

    init?(image: CGImage, trimmingMargins: Bool = true) {
        // Trimming is done on a small copy: the bars are big, and finding
        // their edges to within half a percent is plenty.
        let sampleWidth = 320
        let sampleHeight = max(1, Int((Double(image.height) / Double(image.width) * Double(sampleWidth)).rounded()))
        guard let sample = ImageFingerprint.render(image, width: sampleWidth, height: sampleHeight),
              let content = trimmingMargins
                ? ImageFingerprint.contentBounds(sample, width: sampleWidth, height: sampleHeight)
                : CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight) else {
            return nil
        }
        let normalised = CGRect(x: content.minX / CGFloat(sampleWidth), y: content.minY / CGFloat(sampleHeight),
                                width: content.width / CGFloat(sampleWidth), height: content.height / CGFloat(sampleHeight))
        // Cropped from the full image, so a small reference image and a big
        // capture are both reduced from as much detail as they have.
        let crop = CGRect(x: normalised.minX * CGFloat(image.width), y: normalised.minY * CGFloat(image.height),
                          width: normalised.width * CGFloat(image.width), height: normalised.height * CGFloat(image.height)).integral
        guard let cropped = image.cropping(to: crop),
              let grid = ImageFingerprint.render(cropped, width: ImageFingerprint.width, height: ImageFingerprint.height) else {
            return nil
        }
        var values: [Float] = []
        values.reserveCapacity(ImageFingerprint.width * ImageFingerprint.height * 3)
        for pixel in 0..<(ImageFingerprint.width * ImageFingerprint.height) {
            for channel in 0..<3 {
                values.append(Float(grid[pixel * 4 + channel]) / 255)
            }
        }
        self.values = values
        self.contentRect = normalised
    }

    /// The image's trimmed content — what a fingerprint is taken of — as a
    /// small image, for saving as a reference to match captures against.
    static func content(of image: CGImage, width: Int) -> CGImage? {
        guard let fingerprint = ImageFingerprint(image: image) else { return nil }
        let rect = fingerprint.contentRect
        let crop = CGRect(x: rect.minX * CGFloat(image.width), y: rect.minY * CGFloat(image.height),
                          width: rect.width * CGFloat(image.width), height: rect.height * CGFloat(image.height)).integral
        guard let cropped = image.cropping(to: crop) else { return nil }
        let height = max(1, Int((Double(cropped.height) / Double(cropped.width) * Double(width)).rounded()))
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Private

    /// A channel above this, out of 255, is picture rather than margin.
    private static let darkThreshold: UInt8 = 24
    /// A row or column is picture once this fraction of its pixels are. A bar
    /// is dark all along, but not always entirely: some frames have a line a
    /// few pixels thick along the window's edge, and an app that draws its own
    /// cursor can leave it out in a bar. Both stay under this. So does a lone
    /// line of thin lettering on black, which then fingerprints as blank.
    private static let contentFraction = 0.15

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    /// The image scaled to `width`×`height`, as RGBX bytes, top row first.
    private static func render(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        // A bitmap context's rows run top to bottom in memory
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    /// The smallest rectangle, in sample pixels with a top-left origin, that
    /// holds every row and column with enough non-dark pixels in it.
    private static func contentBounds(_ pixels: [UInt8], width: Int, height: Int) -> CGRect? {
        var rowCounts = [Int](repeating: 0, count: height)
        var columnCounts = [Int](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) > darkThreshold {
                    rowCounts[y] += 1
                    columnCounts[x] += 1
                }
            }
        }
        let rowMinimum = max(1, Int(Double(width) * contentFraction))
        let columnMinimum = max(1, Int(Double(height) * contentFraction))
        guard let top = rowCounts.firstIndex(where: { $0 >= rowMinimum }),
              let bottom = rowCounts.lastIndex(where: { $0 >= rowMinimum }),
              let left = columnCounts.firstIndex(where: { $0 >= columnMinimum }),
              let right = columnCounts.lastIndex(where: { $0 >= columnMinimum }) else {
            return nil
        }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
}
