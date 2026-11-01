//
//  BuildWindow.swift
//  SecondChance
//
//  A window onto a build the main window isn't following: each integration
//  test builds through a view model of its own, and this shows that view
//  model's screens, as a person building the game would see them. Not with
//  SECOND_CHANCE_HIDE_TEST_UI, which keeps the test host's windows hidden.

import AppKit
import SwiftUI
import SecondChanceKit

@MainActor
final class BuildWindow {
    private let window: NSWindow
    /// Where the next window goes, so builds side by side don't stack.
    private static var nextTopLeft = NSPoint.zero

    private init(window: NSWindow) {
        self.window = window
    }

    /// Show `viewModel`'s screens in a window titled `title`, or nothing
    /// when the test host keeps its windows hidden.
    static func show(_ viewModel: WrappBuildViewModel, title: String) -> BuildWindow? {
        guard !TestHost.hidesUI else { return nil }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: ContentView.size),
            styleMask: [.titled, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(viewModel))
        if nextTopLeft == .zero {
            window.center()
            nextTopLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        }
        nextTopLeft = window.cascadeTopLeft(from: nextTopLeft)
        // On screen without making the test host active, which would take
        // the keyboard from a game another test is launching: `orderFront`
        // leaves an inactive app's window off screen altogether.
        window.orderFrontRegardless()
        return BuildWindow(window: window)
    }

    func close() {
        window.close()
    }
}
