//
//  Configuration.swift
//  GamePuppeteer
//
//  Configuration, plist reading, and result types for the game launch test tool.

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
}

enum GamePuppetExitCode: Int32 {
    case passed = 0
    case failed = 1
    case forcedQuit = 2
    case permissionDeniedAccessibility = 3
    case permissionDeniedScreenRecording = 4
    case permissionRelaunchRequiredScreenRecording = 5
}

/// Typed result of running a puppet session.
enum GamePuppetResult {
    case passed
    case forcedQuit
    case failed(String)

    var exitCode: Int32 {
        switch self {
        case .passed: return GamePuppetExitCode.passed.rawValue
        case .forcedQuit: return GamePuppetExitCode.forcedQuit.rawValue
        case .failed: return GamePuppetExitCode.failed.rawValue
        }
    }
}

// Template match cache for adaptive search across script executions
struct TemplateMatchCache: Codable {
    let x: Int
    let y: Int
    let timestamp: TimeInterval
}

let cacheFilePath = "/tmp/game-puppeteer-template-cache.json"

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
