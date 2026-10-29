//
//  PictureFrameCheck.swift
//  WrappPuppeteer
//
//  Checks that a picture of a known shape is framed rightly in a window of
//  another shape: kept at its own shape, centred, with dark bars beside it.
//  Everything outside where the picture should be must then be dark. Light
//  there is either a bar left undrawn -- a window's own background, one flat
//  colour from end to end -- or the picture itself, stretched out over where
//  the bars should be.

import Foundation
import CoreGraphics
import ImageIO

enum PictureFrameCheck {
    /// Something light in one of the bars.
    struct Finding {
        /// Which bar: left, right, top or bottom.
        let bar: String
        /// How much of it isn't dark, 0…1.
        let lightFraction: Double
        /// Its colour, as `#rrggbb`, when the light is one flat colour — an
        /// undrawn bar rather than a picture spilling into it.
        let flatColour: String?
    }

    /// What's light in the bars a picture of `pictureAspect` (width over
    /// height), fitted and centred, leaves in `image`. Empty when they're
    /// dark, and when the image has the picture's shape and so no bars.
    static func findings(in image: CGImage, pictureAspect: Double) -> [Finding] {
        let width = sampleWidth
        let height = max(1, Int((Double(image.height) / Double(image.width) * Double(width)).rounded()))
        guard pictureAspect > 0, let pixels = ImageFingerprint.render(image, width: width, height: height) else { return [] }
        return bars(width: width, height: height, pictureAspect: pictureAspect).compactMap { bar in
            finding(in: bar.rect, named: bar.name, pixels: pixels, width: width)
        }
    }

    /// The image in a file, for checking; nil if it can't be read.
    static func image(atPath path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Private

    /// The image is checked at this width: the bars are a large part of it,
    /// and a full-size capture of a Retina display is tens of megabytes.
    private static let sampleWidth = 640
    /// Left out along the bars' inner edge, in sample pixels, for where the
    /// picture's edge is blurred or rounded, and along the image's outer edge,
    /// where some windows have a thin line.
    private static let innerMargin = 3
    private static let outerMargin = 2
    /// The top of the side bars is left out too, as this fraction of the
    /// height: a fullscreen window with a title bar has it, under the menu
    /// bar's place, across the top of a capture of it.
    private static let titleBarAllowance = 0.04
    /// A channel above this, out of 255, isn't dark (as `ImageFingerprint`).
    private static let darkThreshold = 24
    /// A bar fails once this much of it isn't dark: a cursor out in a bar
    /// stays well under it.
    private static let lightLimit = 0.02
    /// Light that is nearly all of a bar, varying in brightness by less than
    /// this standard deviation out of 255, is one flat colour.
    private static let flatFraction = 0.95
    private static let flatDeviation = 4.0

    /// The bars beside a fitted, centred picture, in sample pixels with a
    /// top-left origin, each without its margins; none narrower than a pixel.
    private static func bars(width: Int, height: Int, pictureAspect: Double) -> [(name: String, rect: CGRect)] {
        let w = Double(width), h = Double(height)
        var bars: [(name: String, rect: CGRect)] = []
        if w / h > pictureAspect {
            let barWidth = (w - h * pictureAspect) / 2
            let depth = barWidth - Double(innerMargin + outerMargin)
            guard depth >= 1 else { return [] }
            let top = (h * titleBarAllowance).rounded(.up)
            bars.append(("left", CGRect(x: Double(outerMargin), y: top, width: depth, height: h - top)))
            bars.append(("right", CGRect(x: w - barWidth + Double(innerMargin), y: top, width: depth, height: h - top)))
        } else {
            let barHeight = (h - w / pictureAspect) / 2
            let depth = barHeight - Double(innerMargin + outerMargin)
            guard depth >= 1 else { return [] }
            bars.append(("top", CGRect(x: 0, y: Double(outerMargin), width: w, height: depth)))
            bars.append(("bottom", CGRect(x: 0, y: h - barHeight + Double(innerMargin), width: w, height: depth)))
        }
        return bars
    }

    private static func finding(in rect: CGRect, named name: String, pixels: [UInt8], width: Int) -> Finding? {
        let rect = rect.integral
        var light: [(Int, Int, Int)] = []
        var total = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let offset = (y * width + x) * 4
                let pixel = (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
                total += 1
                if max(pixel.0, pixel.1, pixel.2) > darkThreshold { light.append(pixel) }
            }
        }
        guard total > 0 else { return nil }
        let fraction = Double(light.count) / Double(total)
        guard fraction > lightLimit else { return nil }
        return Finding(bar: name, lightFraction: fraction, flatColour: fraction >= flatFraction ? flatColour(of: light) : nil)
    }

    /// The pixels' mean colour as `#rrggbb` if their brightness hardly varies.
    private static func flatColour(of pixels: [(Int, Int, Int)]) -> String? {
        let brightness = pixels.map { Double($0.0 + $0.1 + $0.2) / 3 }
        let mean = brightness.reduce(0, +) / Double(brightness.count)
        let variance = brightness.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(brightness.count)
        guard variance.squareRoot() < flatDeviation else { return nil }
        let count = pixels.count
        return String(format: "#%02x%02x%02x", pixels.reduce(0) { $0 + $1.0 } / count,
                      pixels.reduce(0) { $0 + $1.1 } / count, pixels.reduce(0) { $0 + $1.2 } / count)
    }
}
