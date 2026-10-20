//
//  ScreenCapture.swift
//  WrappPuppeteer
//
//  Screenshots of the whole screen or a single window, via screencapture(1).

import Foundation
import ImageIO
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.ScreenCapture")

enum ScreenCapture {
    /// Capture the whole screen to a timestamped PNG and return its path.
    /// The caller owns the file.
    static func captureScreen(prefix: String = "wrapp-puppeteer") -> String? {
        let path = "/tmp/\(prefix)-\(Int(Date().timeIntervalSince1970)).png"
        return run(arguments: ["-x", path]) ? path : nil
    }

    /// Capture a single window by its window number to a timestamped PNG.
    /// Only that window's own pixels: nothing in front of it shows, and once
    /// it has closed the capture fails rather than showing what was behind.
    /// No shadow (`-o`), so the image is exactly the window's bounds.
    @discardableResult
    static func captureWindow(number: Int32, prefix: String = "wrapp-puppeteer-window") -> String? {
        let path = "/tmp/\(prefix)-\(Int(Date().timeIntervalSince1970)).png"
        return run(arguments: ["-x", "-o", "-l\(number)", path]) ? path : nil
    }

    /// An image file's size in pixels.
    static func pixelSize(ofImageAt path: String) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func run(arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = arguments

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            logger.warning("⚠️  Failed to capture screenshot: \(error)")
            return false
        }
    }
}
