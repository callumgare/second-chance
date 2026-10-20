//
//  ScreenCapture.swift
//  WrappPuppeteer
//
//  A screenshot of the whole screen, via screencapture(1), for diagnosing a
//  failure when WrappPuppeteer happens to have Screen Recording. It doesn't
//  need it: the game captures its own window (InProcessControl). Each run of
//  screencapture also wears down systemstatusd (docs/testing.md), so this is
//  for failures only.

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
