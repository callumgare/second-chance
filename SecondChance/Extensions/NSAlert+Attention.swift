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

    /// `runModal()` with Second Chance, and so the question, brought to the
    /// front: for a question that follows on at once from something the
    /// person did in another app's window, as which game to get does from
    /// signing in in Steam's or Big Fish's, where they're still at the Mac
    /// and the question would otherwise open behind that window.
    @MainActor
    func runModalInFront() -> NSApplication.ModalResponse {
        if NSApp.activationPolicy() == .regular {
            NSApp.installerWindow?.orderFront(nil)
            // The plain activate() is only a request since macOS 14, which
            // the store's window, active as the person signed in, can keep.
            NSApp.activate(ignoringOtherApps: true)
        }
        return runModal()
    }
}
