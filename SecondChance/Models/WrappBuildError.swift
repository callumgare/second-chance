//
//  WrappBuildError.swift
//  SecondChance
//
//  Errors thrown while building a wrapp. Relocated from GameInstaller.swift
//  when the per-source builders replaced it.
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
        }
    }

    static let cancelled = WrappBuildError.userCancelled
}
