//
//  InputAutomation.swift
//  WrappPuppeteer
//
//  The ring drawn where WrappPuppeteer clicks. The clicks themselves are
//  posted by the app under test, into its own window (InProcessControl).

import Foundation
import AppKit
import CoreGraphics
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.InputAutomation")

// MARK: - Click feedback

enum InputControl {
    private static let clickAnimationDuration: TimeInterval = 0.5

    /// Show a visual click animation at the specified point
    static func showClickAnimation(at point: CGPoint) {
        guard let screen = NSScreen.main else { return }

        // Create a window to show the click animation
        let size: CGFloat = 60
        let windowRect = NSRect(
            x: point.x - size/2,
            y: screen.frame.height - point.y - size/2, // Convert to AppKit coordinates
            width: size,
            height: size
        )

        let window = NSWindow(
            contentRect: windowRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.hasShadow = false
        // A game in native fullscreen has a Space of its own, and our
        // windows otherwise stay on the desktop's, behind it.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // Create a custom view for the animation
        let animationView = ClickAnimationView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        window.contentView = animationView

        // Show the window
        window.orderFrontRegardless()

        // Animate and close
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = clickAnimationDuration
                animationView.animator().alphaValue = 0.0
            }, completionHandler: {
                window.close()
            })
        }
    }

    /// Show the click ring at a screen point, and turn the main run loop for
    /// the length of its fade. The scenario runs on the main thread and
    /// otherwise only ever sleeps, so without that AppKit wouldn't put the
    /// ring's window on screen, or fade and close it, until the process exited.
    static func showClick(at point: CGPoint) {
        showClickAnimation(at: point)
        if Thread.isMainThread {
            RunLoop.current.run(until: Date().addingTimeInterval(clickAnimationDuration + 0.1))
        }
    }
}

// MARK: - Click Animation View

class ClickAnimationView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // Draw outer ring
        context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(4.0)
        context.addArc(center: center, radius: bounds.width/2 - 2, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        context.strokePath()

        // Draw inner dot
        context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.6).cgColor)
        context.addArc(center: center, radius: 6, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        context.fillPath()
    }
}
