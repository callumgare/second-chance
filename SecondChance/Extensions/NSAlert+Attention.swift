//
//  NSAlert+Attention.swift
//  SecondChance
//
//  A build asks its questions part way through, often while the person has
//  gone off to do something else (the progress screen says they can). Each
//  question bounces the Dock icon until they come back to it.

import AppKit

extension NSApplication {
    /// Bounce the Dock icon until Second Chance is brought to the front, if
    /// it isn't already. Nothing in a headless run, which has no Dock icon.
    @MainActor
    func askForAttention() {
        guard !isActive, activationPolicy() == .regular else { return }
        requestUserAttention(.criticalRequest)
    }

    /// Second Chance's own window, for sheets: not Settings or the log
    /// window, which may be the key window at the time.
    @MainActor
    var installerWindow: NSWindow? {
        windows.first { $0.identifier?.rawValue.hasPrefix(SecondChanceApp.mainWindowID) == true && $0.isVisible }
            ?? mainWindow
    }
}

extension NSAlert {
    /// `runModal()`, asking for attention first if Second Chance is in the
    /// background.
    @MainActor
    func runModalAskingForAttention() -> NSApplication.ModalResponse {
        NSApp.askForAttention()
        return runModal()
    }
}
