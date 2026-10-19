//
//  LoadingStage.swift
//  Shared
//
//  The steps a wrapp's loading window walks through while a game starts, and
//  how long each may take before the window says so. Used by the wrapp's
//  InfoWindowView; here so the unit tests can reach it.

import Foundation

/// What the wrapp is waiting on while the info window shows its spinner:
/// what to tell the player, and how long before saying it's slow, then that
/// it may have failed. Each stage starts its own clock.
enum LoadingStage: Equatable {
    /// The wrapp starting the game itself.
    case startingGame(title: String)
    /// Steam starting up, which on its first run includes updating itself.
    case startingSteam
    /// Steam waiting for the player to sign in: no clock, since it's
    /// waiting on them.
    case signingInToSteam
    /// Steam starting the game (`-applaunch`).
    case steamStartingGame(title: String)

    var message: String {
        switch self {
        case .startingGame(let title): return "Starting \(title)…"
        case .startingSteam: return "Starting Steam…"
        case .signingInToSteam: return "Sign in to Steam in its window — you can scan the QR code with the Steam app."
        case .steamStartingGame(let title): return "Steam is starting \(title)…"
        }
    }

    /// A line under the message, saying why this step is there.
    var detail: String? {
        switch self {
        case .startingSteam:
            return "This game needs Steam running. The first time, Steam updates itself, which can take several minutes."
        case .startingGame, .signingInToSteam, .steamStartingGame:
            return nil
        }
    }

    /// What a slow start or a possible failure is about.
    var subject: String {
        switch self {
        case .startingSteam, .signingInToSteam: return "Steam"
        case .startingGame, .steamStartingGame: return "The game"
        }
    }

    /// When to say this stage is taking longer than usual, from its start.
    /// Nil for a stage waiting on the player.
    var slowNoteAfter: TimeInterval? {
        switch self {
        case .startingGame: return 20
        // Steam's own start includes its update on a first run.
        case .startingSteam: return 120
        case .signingInToSteam: return nil
        // Steam takes a while to hand over, even on an idle Mac (about 90 s
        // from -applaunch to the game's window has been seen).
        case .steamStartingGame: return 90
        }
    }

    /// When to say the launch may have failed, from the stage's start.
    var possibleFailureAfter: TimeInterval? {
        switch self {
        case .startingGame: return 50
        case .startingSteam: return 600
        case .signingInToSteam: return nil
        case .steamStartingGame: return 300
        }
    }
}
