//
//  SteamStartupWatch.swift
//  Shared
//
//  What Steam is doing between being started and signing in — starting,
//  updating itself, connecting — for a wrapp's loading window and a build's
//  progress screen alike, so both say the same thing.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Steam")

/// Where a starting Steam has got to before it signs in or asks for a
/// sign-in, which its logs say rather than its window (`SteamLogs`).
public nonisolated enum SteamStartupStage: Equatable, Sendable {
    case starting
    /// Updating itself, which the bootstrapper reports as it goes: each new
    /// phase or download figure is a new stage.
    case updating(SteamLogs.BootstrapPhase)
    /// Started, and connecting to Steam's servers to sign in.
    case connecting

    /// What Steam is doing, in a few words, without a trailing "…".
    public var message: String {
        switch self {
        case .starting: return "Starting Steam"
        case .updating(.extracting), .updating(.installing): return "Installing Steam's update"
        case .updating(.restarting): return "Starting the updated Steam"
        case .updating: return "Updating Steam"
        case .connecting: return "Connecting to Steam"
        }
    }

    /// How far the update's download has got: done and total in kilobytes.
    /// Nil when there's nothing to measure yet.
    public var download: (doneKB: Int64, totalKB: Int64)? {
        guard case .updating(.downloading(let done?, let total?)) = self, total > 0 else { return nil }
        return (min(done, total), total)
    }
}

/// Follows a starting Steam's logs through `check`, logging each step of an
/// update as it goes. One watch for each start of Steam: the client reads
/// only what that start wrote.
public nonisolated struct SteamStartupWatch: Sendable {
    private var lastPhase = SteamLogs.BootstrapPhase.starting
    /// Every start begins at `.starting`, which its caller has already shown.
    private var reported = SteamStartupStage.starting

    public init() {}

    /// The stage Steam is at now, when it differs from the one this last
    /// returned; nil when it hasn't changed.
    public mutating func check(_ client: SteamClientDriving) -> SteamStartupStage? {
        let phase = client.bootstrapPhase()
        if phase != lastPhase {
            Self.log(phase, after: lastPhase)
            lastPhase = phase
        }
        // Once the update is in and the files check out, Steam is starting
        // again, as on any start.
        let now: SteamStartupStage = phase.isUpdating ? .updating(phase) : client.isConnecting() ? .connecting : .starting
        guard now != reported else { return nil }
        reported = now
        return now
    }

    /// A line for each step of an update; download progress only every
    /// tenth of the way, as the bootstrapper reports it four times a second.
    private static func log(_ phase: SteamLogs.BootstrapPhase, after previous: SteamLogs.BootstrapPhase) {
        switch phase {
        case .starting:
            break
        case .verifying:
            logger.notice("[Steam] Checking its files")
        case .verified:
            logger.notice("[Steam] Its files are up to date")
        case .downloading(let done, let total):
            guard let done, let total, total > 0 else {
                if case .downloading = previous { return }
                logger.notice("[Steam] Updating: downloading the update")
                return
            }
            var previousTenth = -1
            if case .downloading(let before?, _) = previous { previousTenth = Int(before * 10 / total) }
            let tenth = Int(done * 10 / total)
            if tenth != previousTenth {
                logger.notice("[Steam] Updating: downloaded \(done / 1024) of \(total / 1024) MB")
            }
        case .extracting:
            logger.notice("[Steam] Updating: extracting the update")
        case .installing:
            logger.notice("[Steam] Updating: installing the update")
        case .restarting:
            logger.notice("[Steam] Updated: starting the new version")
        }
    }
}
