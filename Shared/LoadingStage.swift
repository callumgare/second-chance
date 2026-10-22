//
//  LoadingStage.swift
//  Shared
//
//  The steps a wrapp's loading window walks through while a game starts, and
//  how long each may take before the window says so. Used by the wrapp's
//  InfoWindowView; here so the unit tests can reach it.

import Foundation

/// What the wrapp is waiting on while the info window shows its spinner:
/// what to tell the player, and when to say it's slow, then that it may have
/// failed. Each stage starts its own clock.
///
/// "May have failed" needs two things: the stage has gone on longer than it
/// takes on even a busy Mac (`possibleFailureAfter`), and the launch has
/// shown no sign of getting anywhere for `stallAfter` — no Wine program using
/// the CPU or starting, no new log lines, whichever of those the stage counts
/// (`countsAsProgress`). A launch that is merely slow keeps showing those, so
/// it's left be; one that is stuck shows nothing, and the window says so as
/// soon as it's past the time the stage normally takes.
/// docs/wrapp-launch.md has the measurements
/// these numbers come from.
enum LoadingStage: Equatable {
    /// The wrapp starting the game itself, until the game's window appears.
    case startingGame(title: String)
    /// Steam starting up, until it signs in or asks the player to.
    case startingSteam
    /// Steam updating itself before it starts: what the bootstrapper is
    /// doing, with the download's progress once it says.
    case updatingSteam(SteamLogs.BootstrapPhase)
    /// Steam started, and connecting to its servers to sign in. Online that
    /// takes a couple of seconds; offline, Steam keeps trying — writing to
    /// its logs as it does — so only the time counts here.
    case connectingToSteam
    /// Steam waiting for the player to sign in: no clock, since it's
    /// waiting on them.
    case signingInToSteam
    /// Steam starting the game (`-applaunch`).
    case steamStartingGame(title: String)
    /// Steam's launch waiting for the player to say whether to stop the game
    /// the account is playing on another computer: no clock, since it's
    /// waiting on them.
    case steamPlayingElsewhere
    /// Steam's launch waiting on some other question in its window: no
    /// clock, since it's waiting on them.
    case steamWaitingForPlayer
    /// The game's Wine from the last time it was played still closing down.
    /// That takes seconds; past `possibleFailureAfter` the window offers to
    /// stop it, while still waiting.
    case lastSessionClosing

    var message: String {
        switch self {
        case .startingGame(let title): return "Starting \(title)…"
        case .startingSteam: return "Starting Steam…"
        case .updatingSteam(let phase):
            switch phase {
            case .extracting, .installing: return "Installing Steam's update…"
            case .restarting: return "Starting the updated Steam…"
            default: return "Updating Steam…"
            }
        case .connectingToSteam: return "Connecting to Steam…"
        case .signingInToSteam: return "Sign in to Steam"
        case .steamStartingGame(let title): return "Steam is starting \(title)…"
        case .steamPlayingElsewhere: return "Your Steam account is playing on another computer"
        case .steamWaitingForPlayer: return "Steam is waiting for you"
        case .lastSessionClosing: return "Waiting for the game to finish closing…"
        }
    }

    /// A line under the message, saying why this step is there.
    var detail: String? {
        switch self {
        case .startingSteam:
            return "This game plays through Steam, so it's starting Steam for you first."
        case .updatingSteam:
            return "Steam is updating itself, as it does now and then. The game starts once it's done."
        case .connectingToSteam:
            return "This game needs Steam signed in, which needs the internet."
        case .signingInToSteam:
            return "Use Steam's window, or scan its QR code with the Steam app on your phone."
        case .steamPlayingElsewhere:
            return "Steam can only play one game at a time. Answer Steam's question to stop the game there and play here."
        case .steamWaitingForPlayer:
            return "Answer the question in Steam's window, and the game will carry on starting."
        case .lastSessionClosing:
            return "It's still closing from the last time it was played. That usually takes a few seconds."
        case .startingGame, .steamStartingGame:
            return nil
        }
    }

    /// How far a download has got, for a progress bar: done and total in
    /// kilobytes. Nil when there's nothing to measure yet.
    var progress: (doneKB: Int64, totalKB: Int64)? {
        guard case .updatingSteam(.downloading(let done?, let total?)) = self, total > 0 else { return nil }
        return (min(done, total), total)
    }

    /// "217 of 255 MB", under the progress bar.
    var progressText: String? {
        guard let progress else { return nil }
        return "\(progress.doneKB / 1024) of \(progress.totalKB / 1024) MB"
    }

    /// The stage's name in the log: its case, without a title.
    var logName: String {
        switch self {
        case .startingGame: return "startingGame"
        case .startingSteam: return "startingSteam"
        case .updatingSteam: return "updatingSteam"
        case .connectingToSteam: return "connectingToSteam"
        case .signingInToSteam: return "signingInToSteam"
        case .steamStartingGame: return "steamStartingGame"
        case .steamPlayingElsewhere: return "steamPlayingElsewhere"
        case .steamWaitingForPlayer: return "steamWaitingForPlayer"
        case .lastSessionClosing: return "lastSessionClosing"
        }
    }

    /// What a slow start or a possible failure is about.
    var subject: String {
        switch self {
        case .startingSteam, .updatingSteam, .connectingToSteam, .signingInToSteam, .steamPlayingElsewhere, .steamWaitingForPlayer:
            return "Steam"
        case .startingGame, .steamStartingGame, .lastSessionClosing: return "The game"
        }
    }

    /// What the window says when the launch may have failed in this stage.
    var possibleFailureText: String {
        let options = "It's still trying, so you can keep waiting — or look at the log, or quit."
        switch self {
        case .connectingToSteam:
            return "Steam can't reach its servers. Check that this Mac is connected to the internet. \(options)"
        case .updatingSteam:
            return "Steam's update has stopped getting anywhere, and may have failed. Check that this Mac is connected to the internet. \(options)"
        default:
            return "\(subject) is taking much longer than usual to start, and may have failed. \(options)"
        }
    }

    /// Whether the stage waits on the player rather than the Mac: it never
    /// counts as slow.
    var isWaitingOnThePlayer: Bool {
        switch self {
        case .signingInToSteam, .steamPlayingElsewhere, .steamWaitingForPlayer: return true
        default: return false
        }
    }

    /// When to say this stage is taking longer than usual, from its start.
    /// Nil for a stage waiting on the player.
    var slowNoteAfter: TimeInterval? {
        switch self {
        // Of 529 launches logged on two Macs, none took longer than 15 s
        // from the click to the game's window.
        case .startingGame: return 20
        // Steam has signed in 22–77 s after it started, on an idle Mac.
        case .startingSteam: return 90
        // Online, it connects in a couple of seconds.
        case .connectingToSteam: return 20
        // Each new progress line starts the stage's clock again.
        case .updatingSteam: return nil
        case .signingInToSteam, .steamPlayingElsewhere, .steamWaitingForPlayer, .lastSessionClosing: return nil
        // Usually under 10 s from -applaunch to the window, but Steam's
        // ShowInterstitials step has taken 30 s by itself.
        case .steamStartingGame: return 30
        }
    }

    /// How much longer a stage gets, before it may count as failed, while the
    /// Mac is heavily loaded — if it's one whose speed depends on the CPU.
    static let heavyLoadFactor: TimeInterval = 3

    /// Whether how long the stage takes depends on the CPU, so that a busy
    /// Mac gives it longer. Not a download, a connection, or Wine's last
    /// session closing.
    var slowsUnderLoad: Bool {
        switch self {
        case .startingGame, .startingSteam, .steamStartingGame: return true
        default: return false
        }
    }

    /// The least time the stage has had before the window may say the launch
    /// may have failed, from the stage's start: longer than it takes on a
    /// busy Mac. Past it, the stage also has to have stalled (`stallAfter`).
    var possibleFailureAfter: TimeInterval? {
        switch self {
        case .startingGame: return 30
        case .startingSteam: return 120
        case .connectingToSteam: return 60
        case .updatingSteam: return 0
        case .signingInToSteam, .steamPlayingElsewhere, .steamWaitingForPlayer: return nil
        case .steamStartingGame: return 60
        // It closes within seconds; past this, the window offers to stop it.
        case .lastSessionClosing: return 3
        }
    }

    /// How long the launch must show no progress, as `countsAsProgress`
    /// judges it, before it counts as stalled. Nil when only the time in
    /// the stage matters.
    var stallAfter: TimeInterval? {
        switch self {
        // The longest a launch that worked went without a sign, on a Mac
        // with every core busy: 7 s starting a game, 83 s starting Steam,
        // and 30 s while Steam's ShowInterstitials step waited by itself.
        case .startingGame: return 20
        case .startingSteam: return 45
        case .steamStartingGame: return 45
        // The bootstrapper logs its download four times a second: 30 s
        // without a new line is a stalled update.
        case .updatingSteam: return 30
        case .connectingToSteam, .signingInToSteam, .steamPlayingElsewhere, .steamWaitingForPlayer, .lastSessionClosing: return nil
        }
    }

    /// Whether `sign` shows the launch is still getting somewhere in this
    /// stage. An update counts only its own progress lines, each a new
    /// stage value that starts its clock again. Steam's own activity counts
    /// nowhere: its programs use the CPU and write to its logs whether it is
    /// getting anywhere or not.
    func countsAsProgress(_ sign: LaunchProgressSign) -> Bool {
        switch sign {
        case .steamCPU, .steamLog: return false
        case .cpu, .newProcess, .output, .steamLaunchStep: break
        }
        switch self {
        case .startingGame, .startingSteam, .steamStartingGame: return true
        case .updatingSteam, .connectingToSteam, .signingInToSteam, .steamPlayingElsewhere, .steamWaitingForPlayer, .lastSessionClosing:
            return false
        }
    }
}

/// A sign that a launch is still getting somewhere, as the wrapp watches it
/// (`LaunchActivityMonitor`).
enum LaunchProgressSign: Equatable, Sendable {
    /// Wine's programs (or ScummVM) used the CPU: the game's, Wine's own,
    /// anything but Steam's.
    case cpu
    /// Steam's own programs used the CPU. They do all the time, idle or
    /// stuck, so it says little.
    case steamCPU
    /// Steam's launch of the game moved on to its next step
    /// (`SteamLogs.launchStep`).
    case steamLaunchStep
    /// A Wine program started.
    case newProcess(String)
    /// Wine, Steam or the game printed a line.
    case output
    /// Steam wrote to its logs.
    case steamLog
}
