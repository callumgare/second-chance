//
//  UIStateShots.swift
//  SecondChanceKit
//
//  `SECOND_CHANCE_UI_STATES=<folder>`: an app draws each of its catalogued
//  UI states into that folder as PNGs, light and dark, and quits.
//  `sc screenshot` runs it for Second Chance and the wrapp
//  (docs/dev-cli.md#screenshots).

import AppKit
import Logging
import ScreenCaptureKit
import SwiftUI

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.UIStateShots")

/// One state of an app's UI to draw: a view set up as it would be then.
public struct UIStateShot {
    /// A short kebab-case name, unique within the app: the PNG's name.
    public let name: String
    /// The title and style its window has, for a picture taken on screen.
    public let title: String
    public let style: NSWindow.StyleMask
    /// The window's content size; a nil height fits the view's own.
    public let width: CGFloat
    public let height: CGFloat?
    public let view: @MainActor () -> AnyView
    /// Run once the view has appeared, before it's drawn: for state a view
    /// resets as it appears (a clock starting afresh, say).
    public let afterAppearing: @MainActor () -> Void

    public init(_ name: String, title: String, style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable],
                width: CGFloat, height: CGFloat? = nil,
                afterAppearing: @escaping @MainActor () -> Void = {}, view: @escaping @MainActor () -> some View) {
        self.name = name
        self.title = title
        self.style = style
        self.width = width
        self.height = height
        self.afterAppearing = afterAppearing
        self.view = { AnyView(view()) }
    }
}

/// Draws an app's catalogued UI states (`UIStateShot`) when
/// `SECOND_CHANCE_UI_STATES` names a folder, each light and dark.
///
/// Normally each is drawn in a window that is never shown, so nothing comes
/// on screen, nothing takes the focus and no permission is needed: safe on a
/// Mac someone is using. Such a picture has no title bar, and a window that's
/// never key draws its default button without the accent colour.
///
/// With `SECOND_CHANCE_UI_STATES_ON_SCREEN=1`, each is shown in a real
/// window, made active, and captured with its title bar and shadow
/// (ScreenCaptureKit; a process may capture its own windows without Screen
/// Recording): what the README's pictures need.
@MainActor
public enum UIStateShots {
    public static let folderEnvVar = "SECOND_CHANCE_UI_STATES"
    /// Comma-separated state names; one ending in `*` is a prefix.
    public static let statesEnvVar = "SECOND_CHANCE_UI_STATES_ONLY"
    public static let onScreenEnvVar = "SECOND_CHANCE_UI_STATES_ON_SCREEN"
    /// `1`: print the states' names, one a line, and quit.
    public static let listEnvVar = "SECOND_CHANCE_UI_STATES_LIST"

    /// Whether this run is drawing states rather than being the app.
    public static var isConfigured: Bool {
        let environment = ProcessInfo.processInfo.environment
        return !(environment[folderEnvVar] ?? "").isEmpty || environment[listEnvVar] == "1"
    }

    /// When asked to, draw `app`'s states as `<app>-<state>-<light|dark>.png`
    /// and quit; otherwise return. Call it before any window is made.
    public static func runIfConfigured(app: String, shots: @MainActor () -> [UIStateShot]) {
        let environment = ProcessInfo.processInfo.environment
        if environment[listEnvVar] == "1" {
            let names = shots().map(\.name).joined(separator: "\n") + "\n"
            FileHandle.standardOutput.write(Data(names.utf8))
            exit(0)
        }
        guard let path = environment[folderEnvVar], !path.isEmpty else { return }
        let folder = URL(fileURLWithPath: path)
        let wanted = (environment[statesEnvVar] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let onScreen = environment[onScreenEnvVar] == "1"
        if onScreen {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApp.finishLaunching()
        } else {
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
        let chosen = shots().filter { shot in wanted.isEmpty || wanted.contains { matches(shot.name, $0) } }
        var failed = chosen.isEmpty
        if chosen.isEmpty { logger.error("📸 No state of \(app)'s is called \(wanted.joined(separator: ", "))") }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for shot in chosen {
                for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let file = folder.appendingPathComponent("\(app)-\(shot.name)-\(look).png")
                    do {
                        let png = onScreen ? try captureOnScreen(shot, appearance: appearance) : try render(shot, appearance: appearance)
                        try png.write(to: file)
                        logger.notice("📸 \(file.path)")
                    } catch {
                        logger.error("📸 Couldn't draw \(shot.name) (\(look)): \(error.localizedDescription)")
                        failed = true
                    }
                }
            }
        } catch {
            logger.error("📸 Couldn't write the UI states to \(folder.path): \(error.localizedDescription)")
            failed = true
        }
        LogStore.shared.flush()
        exit(failed ? 1 : 0)
    }

    /// Whether `name` is what `pattern` asks for: the same, or starting with
    /// it when it ends in `*`.
    nonisolated static func matches(_ name: String, _ pattern: String) -> Bool {
        pattern.hasSuffix("*") ? name.hasPrefix(pattern.dropLast()) : name == pattern
    }

    // MARK: - Off screen

    /// `shot` drawn in `appearance` in a window that's never shown, as a PNG
    /// at the screen's scale.
    static func render(_ shot: UIStateShot, appearance: NSAppearance.Name) throws -> Data {
        let host = NSHostingView(rootView: shot.view().background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: shot.width, height: shot.height ?? 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        settle(shot, in: window, host: host) { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ShotError("couldn't make a bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ShotError("couldn't make a PNG") }
        return png
    }

    /// Lay `host` out at `shot`'s size, let SwiftUI settle (`wait`), apply
    /// what it resets as it appears, and settle again.
    private static func settle(_ shot: UIStateShot, in window: NSWindow, host: NSView, wait: () -> Void) {
        func once() {
            if shot.height == nil {
                host.frame.size = CGSize(width: shot.width, height: 10_000)
                host.layoutSubtreeIfNeeded()
            }
            let size = CGSize(width: shot.width, height: shot.height ?? host.fittingSize.height)
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            wait()
        }
        once()
        shot.afterAppearing()
        once()
    }

    // MARK: - On screen

    /// More than a window's shadow reaches past it on any side, in points.
    private static let shadowRoom: CGFloat = 120

    /// `shot` shown in a real, active window in `appearance`, captured with
    /// its title bar and shadow, as a PNG.
    static func captureOnScreen(_ shot: UIStateShot, appearance: NSAppearance.Name) throws -> Data {
        NSApp.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: shot.view())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: shot.width, height: shot.height ?? 100),
                              styleMask: shot.style, backing: .buffered, defer: false)
        window.title = shot.title
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        settle(shot, in: window, host: host) { handleEvents(for: 0.3) }
        // Resizable for its buttons, as the real window is, but held at its size.
        window.contentMinSize = window.contentRect(forFrameRect: window.frame).size
        window.contentMaxSize = window.contentMinSize
        window.center()
        window.makeKeyAndOrderFront(nil)
        // The plain activate() is only a request since macOS 14, turned down
        // for an app that hasn't finished launching through its own run
        // loop; this one is still honoured as an app starts up.
        NSApp.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(10)
        while !(window.occlusionState.contains(.visible) && window.isKeyWindow), Date() < deadline {
            handleEvents(for: 0.1)
        }
        guard window.occlusionState.contains(.visible) else { throw ShotError("the window never came on screen") }
        // Drawn as key, with nothing left to settle.
        handleEvents(for: 0.5)
        let outcome = Outcome()
        Task { @MainActor in
            do { outcome.result = .success(try await capture(window)) } catch { outcome.result = .failure(error) }
        }
        while outcome.result == nil { handleEvents(for: 0.05) }
        guard let result = outcome.result else { throw ShotError("the capture never finished") }
        return try result.get()
    }

    /// Where the capture's task leaves its result for the loop waiting on it.
    private final class Outcome {
        var result: Result<Data, Error>?
    }

    private static func capture(_ window: NSWindow) async throws -> Data {
        let content = try await SCShareableContent.currentProcess
        guard let shareable = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw ShotError("ScreenCaptureKit doesn't list the window")
        }
        let filter = SCContentFilter(desktopIndependentWindow: shareable)
        let config = SCStreamConfiguration()
        config.ignoreShadowsSingleWindow = false
        config.showsCursor = false
        config.captureResolution = .best
        // The filter's rect is the window without its shadow, and an image
        // that size squeezes the shadow in by shrinking the window. Given
        // room, the window and shadow come out at full size in the top left,
        // so ask for more and crop to what was drawn.
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width + 2 * shadowRoom) * scale)
        config.height = Int((filter.contentRect.height + 2 * shadowRoom) * scale)
        let captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return try png(of: cropToDrawn(captured))
    }

    /// `image` cropped to the pixels that aren't fully transparent.
    private static func cropToDrawn(_ image: CGImage) throws -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { throw ShotError("can't read the captured image") }
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
            throw ShotError("the captured image is empty")
        }
        return cropped
    }

    private static func png(of image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ShotError("can't make a PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShotError("can't make a PNG") }
        return data as Data
    }

    /// Take AppKit's events off the queue and handle them for `seconds`: the
    /// app's own event loop isn't running yet, and becoming active or a
    /// window coming on screen arrives as events.
    private static func handleEvents(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        repeat {
            if let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        } while Date() < until
    }

    private struct ShotError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
