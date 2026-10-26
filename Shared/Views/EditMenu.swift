//
//  EditMenu.swift
//  Shared
//
//  The Edit menu, without which ⌘C can't copy the text of an alert: the
//  text can be selected with or without a menu, but copying it goes through
//  a menu item with that shortcut. Second Chance gets one from SwiftUI; a
//  wrapp builds its own, and needs a stand-in for an alert shown before then.

import AppKit

/// Cut, Copy, Paste and Select All.
@MainActor
func makeEditMenuItem() -> NSMenuItem {
    let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    editMenuItem.submenu = editMenu
    editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    return editMenuItem
}

/// A stand-in menu (Quit and Edit) for an alert a wrapp shows before its
/// `main()` sets up the wrapp's own menu, which replaces it.
@MainActor
func installEditMenuIfNeeded() {
    guard NSApp.mainMenu?.item(withTitle: "Edit") == nil else { return }
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu(title: "Nancy Drew")
    appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)
    mainMenu.addItem(makeEditMenuItem())
    NSApp.mainMenu = mainMenu
}
