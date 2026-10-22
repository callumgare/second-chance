//
//  WindowScreenshots.swift
//  Shared
//
//  Pictures of this process's own windows, for a detailed failure report:
//  what the person was looking at when it failed. A process may capture its
//  own windows without Screen Recording permission (ScreenCaptureKit's
//  current-process content, as ReadmeScreenshot and puppet control do), so
//  this asks for nothing. A wrapp's game draws in Wine's process, not the
//  wrapp's, so a wrapp's pictures are of its own windows only.
//
//  Left out: an open or save panel, which shows the person's folders and
//  files, and the log window, whose lines name them — a picture can't be
//  redacted the way text is.

import AppKit
import Foundation
import Logging
import os
import ScreenCaptureKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Reporting")

nonisolated enum WindowScreenshots {

    /// PNGs of the windows on screen, written into `directory`. Gives up
    /// after `timeout` with none rather than holding the report up: the
    /// windows are listed on the main thread, which a process on its way out
    /// may be blocking while it waits for this very report.
    static func capture(into directory: URL, timeout: TimeInterval = 5) async -> [URL] {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable ([URL]) -> Void = { files in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: files) }
            }
            Task { @MainActor in finish(await captureNow(into: directory)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if !resumed.withLock({ $0 }) {
                    logger.warning("Left the screenshots out of the failure report: the windows weren't listed within \(Int(timeout))s")
                }
                finish([])
            }
        }
    }

    /// Whether `window` may appear in a report's screenshots.
    @MainActor
    static func mayCapture(_ window: NSWindow) -> Bool {
        !(window is NSSavePanel) && window.identifier != LogWindow.windowIdentifier
    }

    @MainActor
    private static func captureNow(into directory: URL) async -> [URL] {
        guard let app = NSApp else { return [] }
        let windows = app.windows.filter { $0.isVisible && $0.occlusionState.contains(.visible) && mayCapture($0) }
        guard !windows.isEmpty else { return [] }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.currentProcess
        } catch {
            logger.warning("Left the screenshots out of the failure report: \(error.localizedDescription)")
            return []
        }
        var files: [URL] = []
        for (index, window) in windows.enumerated() {
            guard let shareable = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { continue }
            let filter = SCContentFilter(desktopIndependentWindow: shareable)
            let config = SCStreamConfiguration()
            config.ignoreShadowsSingleWindow = true
            config.showsCursor = false
            config.captureResolution = .best
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            let file = directory.appendingPathComponent("window-\(index + 1).png")
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                try write(image, to: file)
                files.append(file)
            } catch {
                logger.warning("Couldn't capture the window \"\(window.title)\" for the failure report: \(error.localizedDescription)")
            }
        }
        return files
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
