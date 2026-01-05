//
//  CacheStage.swift
//  SecondChance
//
//  Defines the different stages of wrapper creation that can be cached

import Foundation

/// Represents a stage in the wrapper creation process that can be cached for debugging
enum CacheStage: String, Codable, CaseIterable {
    case base
    case diskGameInstallerCopied = "disk-game-installer-copied"
    case diskGameInstalled = "disk-game-installed"
    case herDownloadGameInstalled = "her-download-game-installed"
    case steamClientInstalled = "steam-client-installed"
    case steamClientLogin = "steam-client-login"
    case steamGameInstalled = "steam-game-installed"
    
    var displayName: String {
        switch self {
        case .base:
            return "Base Wrapper"
        case .diskGameInstallerCopied:
            return "Disk Installer Copied"
        case .diskGameInstalled:
            return "Disk Game Installed"
        case .herDownloadGameInstalled:
            return "Her Download Game Installed"
        case .steamClientInstalled:
            return "Steam Client Installed"
        case .steamClientLogin:
            return "Steam Client Login"
        case .steamGameInstalled:
            return "Steam Game Installed"
        }
    }
    
    /// Returns all stages up to and including this stage
    func allStagesUpToHere() -> [CacheStage] {
        guard let index = CacheStage.allCases.firstIndex(of: self) else {
            return []
        }
        return Array(CacheStage.allCases[0...index])
    }
    
    /// Returns the next stage in the installation process, if any
    var nextStage: CacheStage? {
        guard let index = CacheStage.allCases.firstIndex(of: self),
              index + 1 < CacheStage.allCases.count else {
            return nil
        }
        return CacheStage.allCases[index + 1]
    }
}

/// Metadata stored with a cached wrapper
struct CacheMetadata: Codable {
    let stage: CacheStage
    let gameSlug: String?
    let installationType: InstallationType?
    let timestamp: Date
    let gameExePath: String?
    
    init(
        stage: CacheStage,
        gameSlug: String? = nil,
        installationType: InstallationType? = nil,
        gameExePath: String? = nil
    ) {
        self.stage = stage
        self.gameSlug = gameSlug
        self.installationType = installationType
        self.timestamp = Date()
        self.gameExePath = gameExePath
    }
}
