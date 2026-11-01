//
//  UIStateShots.swift
//  SecondChanceKit
//
//  `SECOND_CHANCE_UI_STATES=<folder>`: an app draws each of its catalogued
//  UI states into that folder as PNGs, light and dark, and quits, without
//  showing a window. `sc app states` runs it for Second Chance and the
//  wrapp (docs/dev-cli.md).

import AppKit
import Logging
import SwiftUI

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.UIStateShots")

/// One state of an app's UI to draw: a view set up as it would be then.
public struct UIStateShot {
    /// A short kebab-case name, unique within the app: the PNG's name.
    public let name: String
    /// The window's content size; a nil height fits the view's own.
    public let width: CGFloat
    public let height: CGFloat?
    public let view: @MainActor () -> AnyView
    /// Run once the view has appeared, before it's drawn: for state a view
    /// resets as it appears (a clock starting afresh, say).
    public let afterAppearing: @MainActor () -> Void

    public init(_ name: String, width: CGFloat, height: CGFloat? = nil,
                afterAppearing: @escaping @MainActor () -> Void = {}, view: @escaping @MainActor () -> some View) {
        self.name = name
        self.width = width
        self.height = height
        self.afterAppearing = afterAppearing
        self.view = { AnyView(view()) }
    }
}

/// Draws an app's catalogued UI states (`UIStateShot`) for review, when
/// `SECOND_CHANCE_UI_STATES` names a folder. Each is drawn in a window that
/// is never shown, so it takes no focus and needs no permission, which
/// makes it safe on a Mac someone is using. A window that's never key
/// draws its default button without the accent colour.
@MainActor
public enum UIStateShots {
    public static let folderEnvVar = "SECOND_CHANCE_UI_STATES"
    /// Comma-separated: only the states whose names start with one of these.
    public static let onlyEnvVar = "SECOND_CHANCE_UI_STATES_ONLY"

    /// When asked to, draw `app`'s states as `<app>-<state>-<light|dark>.png`
    /// and quit; otherwise return. Call it before any window is made.
    public static func runIfConfigured(app: String, shots: @MainActor () -> [UIStateShot]) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment[folderEnvVar], !path.isEmpty else { return }
        let folder = URL(fileURLWithPath: path)
        let only = (environment[onlyEnvVar] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        NSApplication.shared.setActivationPolicy(.prohibited)
        var failed = false
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for shot in shots() where only.isEmpty || only.contains(where: shot.name.hasPrefix) {
                for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let file = folder.appendingPathComponent("\(app)-\(shot.name)-\(look).png")
                    guard let png = render(shot, appearance: appearance) else {
                        logger.error("📸 Couldn't draw \(shot.name) (\(look))")
                        failed = true
                        continue
                    }
                    try png.write(to: file)
                    logger.notice("📸 \(file.path)")
                }
            }
        } catch {
            logger.error("📸 Couldn't write the UI states to \(folder.path): \(error)")
            failed = true
        }
        exit(failed ? 1 : 0)
    }

    /// `shot` drawn in `appearance`, as a PNG at the screen's scale.
    static func render(_ shot: UIStateShot, appearance: NSAppearance.Name) -> Data? {
        let host = NSHostingView(rootView: shot.view().background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: shot.width, height: shot.height ?? 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        // SwiftUI settles over a few turns of the run loop: its layout, and
        // anything a view sets up as it appears.
        func settle() {
            if shot.height == nil {
                host.frame.size = CGSize(width: shot.width, height: 10_000)
                host.layoutSubtreeIfNeeded()
            }
            let size = CGSize(width: shot.width, height: shot.height ?? host.fittingSize.height)
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        settle()
        shot.afterAppearing()
        settle()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
