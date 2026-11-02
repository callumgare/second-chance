//
//  WrappSource.swift
//  WrappFormat
//
//  The installation sources a wrapp can be built from

import Foundation

/// The source a Nancy Drew game wrapp is built from
public nonisolated enum WrappSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case disk = "disk"
    case herDownload = "her-download"
    case steam = "steam"
    case bigFish = "big-fish"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disk:
            return "Game Discs"
        case .herDownload:
            return "Her Interactive Download"
        case .steam:
            return "Steam"
        case .bigFish:
            return "Big Fish Games"
        }
    }

    public var description: String {
        switch self {
        case .disk:
            return "The original CDs"
        case .herDownload:
            return "A Windows or Mac download bought from Her Interactive"
        case .steam:
            return "A game in your Steam library"
        case .bigFish:
            return "A game in your Big Fish library"
        }
    }
}
