//
//  InputAutomation.swift
//  GameTester
//
//  Mouse and keyboard control automation

import Foundation
import AppKit
import CoreGraphics
import os

private let logger = Logger(subsystem: "com.secondchance.gamepuppeteer", category: "InputAutomation")

// MARK: - Mouse & Keyboard Control

enum InputControl {
    /// Show a visual click animation at the specified point
    static func showClickAnimation(at point: CGPoint) {
        // Create a window to show the click animation
        let size: CGFloat = 60
        let windowRect = NSRect(
            x: point.x - size/2,
            y: NSScreen.main!.frame.height - point.y - size/2, // Convert to AppKit coordinates
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
        
        // Create a custom view for the animation
        let animationView = ClickAnimationView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        window.contentView = animationView
        
        // Show the window
        window.orderFrontRegardless()
        
        // Animate and close
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.5
                animationView.animator().alphaValue = 0.0
            }) {
                window.close()
            }
        }
    }
    
    /// Send ESC key press
    static func pressEscape() {
        logger.notice("  → Pressing ESC key...")
        
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: false)
        
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        
        Thread.sleep(forTimeInterval: 0.1)
    }
    
    /// Click at screen coordinates
    static func click(at point: CGPoint) {
        logger.notice("  → Clicking at (\(Int(point.x), privacy: .public), \(Int(point.y), privacy: .public))...")
        
        // Get current mouse position
        let currentEvent = CGEvent(source: nil)
        let currentPosition = currentEvent?.location ?? CGPoint(x: 0, y: 0)
        
        // Smoothly move cursor to target location
        let steps = 15
        let stepDelay: TimeInterval = 0.01  // 10ms between steps
        
        for i in 1...steps {
            let progress = Double(i) / Double(steps)
            // Use ease-out curve for more natural movement
            let easedProgress = 1 - pow(1 - progress, 3)
            
            let interpolatedX = currentPosition.x + (point.x - currentPosition.x) * easedProgress
            let interpolatedY = currentPosition.y + (point.y - currentPosition.y) * easedProgress
            let interpolatedPoint = CGPoint(x: interpolatedX, y: interpolatedY)
            
            CGWarpMouseCursorPosition(interpolatedPoint)
            
            // Create a mouse move event to ensure applications see the movement
            let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: interpolatedPoint, mouseButton: .left)
            moveEvent?.post(tap: .cghidEventTap)
            
            Thread.sleep(forTimeInterval: stepDelay)
        }
        
        // Small pause at target location
        Thread.sleep(forTimeInterval: 0.1)
        
        // Create mouse events at the target position
        let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        
        // Post events
        mouseDown?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        mouseUp?.post(tap: .cghidEventTap)
        
        // Show visual feedback after click (so it doesn't delay the click)
        showClickAnimation(at: point)
        
        Thread.sleep(forTimeInterval: 0.2)
    }
    
    /// Send Cmd+Q to quit
    static func sendQuitCommand() {
        logger.notice("  → Sending Cmd+Q...")
        
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x0C, keyDown: true) // Q key
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x0C, keyDown: false)
        
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        
        keyDown?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        keyUp?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.5)
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
