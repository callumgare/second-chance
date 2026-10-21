//
//  ReadmeScreenshot.swift
//  SecondChance
//
//  `SECOND_CHANCE_SCREENSHOT=<path>`: the app takes the README's screenshot
//  of its main window, writes it to <path> as a PNG and quits, in the
//  appearance `SECOND_CHANCE_SCREENSHOT_APPEARANCE` names (`light` or
//  `dark`; the Mac's own without it). `sc app screenshot` runs it
//  (docs/dev-cli.md). The app captures its own window,
//  which needs no Screen Recording permission.

import AppKit
import Logging
import ScreenCaptureKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.ReadmeScreenshot")

@MainActor
enum ReadmeScreenshot {
    static let pathEnvVar = "SECOND_CHANCE_SCREENSHOT"
    static let appearanceEnvVar = "SECOND_CHANCE_SCREENSHOT_APPEARANCE"
    /// The main window's size, so every screenshot matches.
    static let contentSize = ContentView.size
    /// More than a window's shadow reaches past it on any side, in points.
    private static let shadowRoom: CGFloat = 120

    private static var observers: [NSObjectProtocol] = []
    private static var started = false

    /// Wait for the main window to come on screen, then capture it. The
    /// window can be on screen before or after launch finishes, so this
    /// looks at both: the windows there when launching finishes, and each
    /// window as it comes on screen or becomes key.
    static func startIfConfigured() {
        guard let path = ProcessInfo.processInfo.environment[pathEnvVar], !path.isEmpty else { return }
        logger.notice("📸 Taking the README screenshot once the window is on screen")
        // Set before any window draws, so none is drawn in the other one first.
        switch ProcessInfo.processInfo.environment[appearanceEnvVar]?.lowercased() {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case nil, "": break
        case let other?: logger.warning("Unknown \(appearanceEnvVar) '\(other)', using the Mac's appearance")
        }
        let url = URL(fileURLWithPath: path)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.windows.forEach { consider($0, url: url) } }
        })
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    if let window = notification.object as? NSWindow { consider(window, url: url) }
                }
            })
        }
    }

    private static func consider(_ window: NSWindow, url: URL) {
        guard !started, isMainWindow(window), window.isVisible, window.occlusionState.contains(.visible) else { return }
        started = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        Task { await capture(window, to: url) }
    }

    private static func isMainWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && window.contentView != nil
    }

    private static func capture(_ window: NSWindow, to url: URL) async {
        window.setContentSize(contentSize)
        window.center()
        // Draw at the new size now, so the capture doesn't see the old one.
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        do {
            let content = try await SCShareableContent.currentProcess
            guard let shareable = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw ScreenshotError("ScreenCaptureKit doesn't list the window")
            }
            let filter = SCContentFilter(desktopIndependentWindow: shareable)
            let config = SCStreamConfiguration()
            config.ignoreShadowsSingleWindow = false
            config.showsCursor = false
            config.captureResolution = .best
            // The filter's rect is the window without its shadow, and an
            // image that size squeezes the shadow in by shrinking the window.
            // Given room, the window and shadow come out at full size in the
            // top left, so ask for more and crop to what was drawn.
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int((filter.contentRect.width + 2 * shadowRoom) * scale)
            config.height = Int((filter.contentRect.height + 2 * shadowRoom) * scale)
            let captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let image = try cropToDrawn(captured)
            try write(image, to: url)
            logger.notice("📸 Wrote \(image.width)×\(image.height) screenshot to \(url.path)")
            NSApp.terminate(nil)
        } catch {
            logger.critical("Couldn't take the README screenshot: \(error.localizedDescription)")
            LogStore.shared.flush()
            exit(1)
        }
    }

    /// `image` cropped to the pixels that aren't fully transparent.
    private static func cropToDrawn(_ image: CGImage) throws -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { throw ScreenshotError("can't read the captured image") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        // The context's rows run top to bottom, as the image's do.
        guard maxX >= minX, let cropped = image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else {
            throw ScreenshotError("the captured image is empty")
        }
        return cropped
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ScreenshotError("can't write \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotError("can't write \(url.path)") }
    }

    private struct ScreenshotError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
