//
//  WrappBuildError.swift
//  SecondChance
//
//  Errors thrown while building a wrapp.
//

import Foundation

enum WrappBuildError: LocalizedError, Equatable {
    case unsupportedEngine
    case steamNotFullyImplemented
    case installerNotFound
    case gameExecutableNotFound
    case userCancelled
    case userCancelledBeforeStart
    case diskNotFound
    case autoItNotAvailable
    case autoItScriptNotFound
    case missingRequiredParameter(String)
    case invalidPath(String)
    case internalError(String)
    /// The installer exited cleanly but left less than a full install.
    case installIncomplete(installed: String, expected: String)
    /// The disc is a different game from the one asked for.
    case wrongGame(expected: String, detected: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedEngine:
            return "Unsupported game engine"
        case .steamNotFullyImplemented:
            return "Steam installation not fully implemented"
        case .installerNotFound:
            return "Could not find game installer executable"
        case .gameExecutableNotFound:
            return "Could not find game executable after installation"
        case .userCancelled:
            return "Installation cancelled by user"
        case .userCancelledBeforeStart:
            return "Installation cancelled before it started"
        case .diskNotFound:
            return "Could not find disk-1 or disk-combined directory"
        case .autoItNotAvailable:
            return "AutoIt automation tool not available in bundle"
        case .autoItScriptNotFound:
            return "AutoIt automation script not found in bundle"
        case .missingRequiredParameter(let param):
            return "Missing required parameter: \(param)"
        case .invalidPath(let message):
            return "Invalid path: \(message)"
        case .internalError(let message):
            return message
        case .wrongGame(let expected, let detected):
            return "This disc is \(detected), not \(expected)"
        case .installIncomplete(let installed, let expected):
            return "The game didn't install completely: \(installed), where a full install is at least \(expected)"

        }
    }

    static let cancelled = WrappBuildError.userCancelled

    var isIncompleteInstall: Bool {
        if case .installIncomplete = self { return true }
        return false
    }
}
