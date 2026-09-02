//
//  InstallerType.swift
//  SecondChance
//
//  The kind of Windows installer a game ships with. Determines the silent /
//  interactive arguments and whether AutoIt automation applies.
//  Lives in Models/ so event types (AppEvent) can reference it
//  without depending on a service class.
//

import Foundation

/// Installer types for different game installers
enum InstallerType {
    case msi
    case installShield
    case innoSetup
    case unknown
}
