//
//  ScreenCapture.swift
//  WrappPuppeteer
//
//  Screenshots of the whole screen or a single window, via screencapture(1).

import Foundation
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
    @discardableResult
    static func captureWindow(number: Int32, prefix: String = "wrapp-puppeteer-window") -> String? {
        let path = "/tmp/\(prefix)-\(Int(Date().timeIntervalSince1970)).png"
        return run(arguments: ["-x", "-l\(number)", path]) ? path : nil
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
            logger.error("⚠️  Failed to capture screenshot: \(error)")
            return false
        }
    }
}
