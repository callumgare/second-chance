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
            return "Game Discs"
        case .herDownload:
            return "Her Download"
        case .steam:
            return "Steam"
        }
    }
    
    var description: String {
        switch self {
        case .disk:
            return "The original CDs"
        case .herDownload:
            return "A Windows installer bought from Her Interactive"
        case .steam:
            return "A game in your Steam library"
        }
    }
}
