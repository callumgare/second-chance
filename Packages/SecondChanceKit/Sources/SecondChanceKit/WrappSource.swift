//
//  WrappSource.swift
//  SecondChanceKit
//
//  The installation sources a wrapp can be built from

import Foundation

/// The source a Nancy Drew game wrapp is built from
public nonisolated enum WrappSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case disk = "disk"
    case herDownload = "her-download"
    case steam = "steam"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disk:
            return "Game Discs"
        case .herDownload:
            return "Her Interactive Download"
        case .steam:
            return "Steam"
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
        }
    }
}
