//
//  WrappBuildError.swift
//  SecondChance
//
//  Errors thrown while building a wrapp.
//

import Foundation

enum WrappBuildError: LocalizedError, Equatable {
    case unsupportedEngine
    /// The signed-in Steam account doesn't own the game.
    case steamGameNotOwned(title: String)
    /// Steam needs someone to sign in, and nobody can: a headless build
    /// with no saved session.
    case steamSignInRequired
    /// Steam neither signed in nor asked for credentials in time, or nobody
    /// signed in to the window it showed.
    case steamSignInTimedOut
    /// Steam's own install of the game failed.
    case steamInstallFailed(reason: String)
    /// Another wrapp, or another build, is running Steam.
    case steamInUse(by: String?)
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
    /// The installer exited cleanly but its own record of finishing is
    /// missing (`InstallCompletion`), so the install was cut short.
    case installIncomplete(reason: String)
    /// The finished wrapp couldn't be moved to where it was meant to go.
    case saveFailed(destination: String, reason: String)
    /// The disc is a different game from the one asked for.
    case wrongGame(expected: String, detected: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedEngine:
            return "Unsupported game engine"
        case .steamGameNotOwned(let title):
            return "Your Steam account doesn't own \(title)"
        case .steamSignInRequired:
            return "Steam needs you to sign in, which a headless build can't do. Build once from the app to sign in."
        case .steamSignInTimedOut:
            return "Steam didn't sign in in time"
        case .steamInstallFailed(let reason):
            return "Steam couldn't install the game: \(reason)"
        case .steamInUse(let holder):
            return "Another game is using Steam\(holder.map { " (\($0))" } ?? ""). Quit it and try again."
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
        case .saveFailed(let destination, let reason):
            return "Couldn't save the wrapp to \(destination): \(reason)"
        case .wrongGame(let expected, let detected):
            return "This disc is \(detected), not \(expected)"
        case .installIncomplete(let reason):
            return "The game didn't install completely: \(reason)"

        }
    }

    static let cancelled = WrappBuildError.userCancelled

    var isIncompleteInstall: Bool {
        if case .installIncomplete = self { return true }
        return false
    }
}
