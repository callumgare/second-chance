//
//  AppMenu.swift
//  WrappTemplate
//
//  The wrapp's menu bar: the app menu, Edit, and in debug mode a Debug menu.

import AppKit
import SecondChanceKit

/// The menu bar, whose items `appDelegate` answers.
func makeMainMenu(appDelegate: AppDelegate, config: GameConfig, debugMode: Bool) -> NSMenu {
    let mainMenu = NSMenu()

    // App menu
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu(title: "Nancy Drew")
    appMenuItem.submenu = appMenu

    let reportsItem = NSMenuItem(
        title: "Failure Reports…",
        action: #selector(AppDelegate.showFailureReportSettings),
        keyEquivalent: ""
    )
    reportsItem.target = appDelegate
    appMenu.addItem(reportsItem)
    appMenu.addItem(.separator())

    let quitItem = NSMenuItem(
        title: "Quit",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    appMenu.addItem(quitItem)

    mainMenu.addItem(makeEditMenuItem())

    // Debug menu (only in debug mode)
    if debugMode {
        let debugMenuItem = NSMenuItem()
        mainMenu.addItem(debugMenuItem)
        let debugMenu = NSMenu(title: "Debug")
        debugMenuItem.submenu = debugMenu

        // Create a menu handler to capture config
        let menuHandler = DebugMenuHandler(config: config)

        let openShellItem = NSMenuItem(
            title: "Open Debug Shell",
            action: #selector(DebugMenuHandler.openDebugShell),
            keyEquivalent: ""
        )
        openShellItem.target = menuHandler
        debugMenu.addItem(openShellItem)

        // A menu item's target is weak: the menu keeps the handler alive.
        objc_setAssociatedObject(debugMenu, "debugMenuHandler", menuHandler, .OBJC_ASSOCIATION_RETAIN)
    }

    return mainMenu
}
