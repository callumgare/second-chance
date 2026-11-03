//
//  StoreSignIns.swift
//  SecondChance
//
//  Which stores Second Chance holds a sign-in for, so the app menu offers to
//  sign out of only those.

import AppKit
import SecondChanceKit

/// Whether there's a store sign-in to sign out of, for the app menu's Sign
/// Out items. Builds and the games' apps save and drop sign-ins, so it's
/// looked at again whenever a menu opens or Second Chance comes to the front.
@Observable
final class StoreSignIns {
    /// The Steam sign-in every Steam game's app shares (docs/steam.md).
    private(set) var steam = false
    /// The Big Fish sign-in kept for the next build (docs/big-fish.md).
    private(set) var bigFish = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        for name in [NSMenu.didBeginTrackingNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        steam = SteamSessionStore().hasSession
        bigFish = BigFishSessionStore().hasSession
    }
}
