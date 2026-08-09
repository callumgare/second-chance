//
//  Configuration.swift
//  GameTester
//
//  Configuration and plist reading utilities

import Foundation

// MARK: - Configuration

struct TestConfig {
    let appPath: String
    let windowDetectTimeout: TimeInterval = 60
    let infoWindowDetectionTimeout: TimeInterval = 15
    let quitTimeout: TimeInterval = 90
    let maxRuntime: TimeInterval
    let gameEngine: String
    let debugMode: Bool
    let logFilePath: String?
}

// Template match cache for adaptive search across script executions
struct TemplateMatchCache: Codable {
    let x: Int
    let y: Int
    let timestamp: TimeInterval
}

let cacheFilePath = "/tmp/game-tester-template-cache.json"

// MARK: - Plist Reading

func readPlist(appPath: String, key: String) -> String? {
    let appURL = URL(fileURLWithPath: appPath)
    let settingsPlistPath = appURL.appendingPathComponent("Contents/Resources/AppSettings.plist")
    
    guard let data = try? Data(contentsOf: settingsPlistPath),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let value = plist[key] as? String else {
        return nil
    }
    
    return value
}

func readGameEngine(appPath: String) -> String? {
    return readPlist(appPath: appPath, key: "GameEngine")
}

func readGameExePath(appPath: String) -> String? {
    return readPlist(appPath: appPath, key: "GameExePath")
}

func getWinePrefix(appPath: String) -> URL {
    let appURL = URL(fileURLWithPath: appPath)
    return appURL.appendingPathComponent("Contents/SharedSupport/prefix")
}
