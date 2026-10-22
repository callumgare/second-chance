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
    /// The signed-in Steam account owns none of the games on Steam.
    case steamNoGamesOwned
    /// Steam needs someone to sign in, and nobody can: a headless build
    /// with no saved session.
    case steamSignInRequired
    /// Steam neither signed in nor asked for credentials in time, or nobody
    /// signed in to the window it showed.
    case steamSignInTimedOut
    /// Steam's own install of the game failed.
    case steamInstallFailed(reason: String)
    /// Another wrapp, or another build, is running Steam. The error screen
    /// offers to quit it, as a fallback.
    case steamInUse(SteamLockHolder)
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
    /// A Her Interactive Mac download Second Chance can't take the game
    /// from: not a Cider installer, or one that isn't laid out as expected.
    case unsupportedMacDownload(reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedEngine:
            return "Second Chance doesn't know how to run this game yet."
        case .steamGameNotOwned(let title):
            return "Your Steam account doesn't own \(title)"
        case .steamNoGamesOwned:
            return "Your Steam account doesn't own any of the Nancy Drew games on Steam"
        case .steamSignInRequired:
            return "Steam needs you to sign in, which a headless build can't do. Build once from the app to sign in."
        case .steamSignInTimedOut:
            return "Steam didn't finish signing in. Try again, and sign in when Steam's window appears."
        case .steamInstallFailed(let reason):
            return "Steam couldn't install the game: \(reason)"
        case .steamInUse(let holder):
            if holder.isBuild {
                return "Second Chance is already adding a game from Steam, and only one game can use Steam at a time. Wait for it to finish and try again."
            }
            guard let name = holder.name.map(SteamLockHolder.quoted) else {
                return "Another game is using Steam, and only one game can use it at a time. Quit it and try again."
            }
            return "\(name) is using Steam, and only one game can use it at a time. Save your game in \(name) and quit it, then click Try Again."
        case .installerNotFound:
            return "Couldn't find the game's installer. Check that it's the first disc of a Nancy Drew game, or the file you downloaded from Her Interactive."
        case .gameExecutableNotFound:
            return "The installer finished, but the game wasn't installed. Try again, and if the installer asks you questions, choose the options it suggests."
        case .userCancelled:
            return "You cancelled installing the game."
        case .userCancelledBeforeStart:
            return "You cancelled before installing started."
        case .diskNotFound:
            return "Couldn't find the files copied from the game disc. Try again."
        case .autoItNotAvailable:
            return "Part of Second Chance is missing (AutoIt). Download Second Chance again and try once more."
        case .autoItScriptNotFound:
            return "Part of Second Chance is missing (an AutoIt script). Download Second Chance again and try once more."
        case .missingRequiredParameter(let param):
            return "Missing required parameter: \(param)"
        case .invalidPath(let message):
            return "Second Chance can't install from that: \(message)"
        case .internalError(let message):
            return message
        case .saveFailed(let destination, let reason):
            return "Couldn't save the game's app to \(destination): \(reason)"
        case .wrongGame(let expected, let detected):
            return "This disc is \(detected), not \(expected)"
        case .installIncomplete(let reason):
            return "The game didn't install completely: \(reason)"
        case .unsupportedMacDownload(let reason):
            return "Second Chance can't use this Mac download: \(reason). Download the Windows version from Her Interactive instead."

        }
    }

    static let cancelled = WrappBuildError.userCancelled

    var isIncompleteInstall: Bool {
        if case .installIncomplete = self { return true }
        return false
    }
}
