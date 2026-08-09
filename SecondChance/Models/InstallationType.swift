//
//  InstallationType.swift
//  SecondChance
//
//  Defines the different types of game installations supported

import Foundation

/// The type of installation source for a Nancy Drew game
enum InstallationType: String, CaseIterable, Identifiable, Codable {
    case disk = "disk"
    case herDownload = "her-download"
    case steam = "steam"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .disk:
            return "Game Disk(s)"
        case .herDownload:
            return "Her Download"
        case .steam:
            return "Steam"
        }
    }
    
    var description: String {
        switch self {
        case .disk:
            return "Install from the original game CDs"
        case .herDownload:
            return "Install from a Windows game installer purchased from Her Interactive"
        case .steam:
            return "Install from Steam"
        }
    }
}
