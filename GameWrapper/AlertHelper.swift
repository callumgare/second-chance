//
//  AlertHelper.swift
//  GameWrapper
//
//  Standalone alert display utility.

import Foundation
import AppKit

func showAlert(message: String, informativeText: String) {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = informativeText
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
