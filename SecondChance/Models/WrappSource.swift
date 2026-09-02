//
//  WrappSource.swift
//  SecondChance
//
//  The installation sources a wrapp can be built from

import Foundation

/// The source a Nancy Drew game wrapp is built from
enum WrappSource: String, CaseIterable, Identifiable, Codable {
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
