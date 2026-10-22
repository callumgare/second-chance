//
//  LoadingClock.swift
//  Shared
//
//  When the loading window says a stage is slow, and when it says the launch
//  may have failed. The wrapp's InfoWindowViewModel keeps one per stage;
//  here so the unit tests can reach it.

import Foundation

/// A stage's clock: how long it has run, and how long since the launch last
/// showed progress that counts in it (`LoadingStage.countsAsProgress`).
struct LoadingClock {
    let stage: LoadingStage
    let started: Date
    private(set) var lastProgress: Date
    /// While the Mac is heavily loaded (`SystemLoadReading.isHeavy`), a stage
    /// that `slowsUnderLoad` gets `LoadingStage.heavyLoadFactor` times as long.
    var heavyLoad = false

    init(stage: LoadingStage, started: Date = Date()) {
        self.stage = stage
        self.started = started
        lastProgress = started
    }

    mutating func note(_ sign: LaunchProgressSign, at date: Date = Date()) {
        guard stage.countsAsProgress(sign), date > lastProgress else { return }
        lastProgress = date
    }

    /// Whether to say the stage is taking longer than usual.
    func isSlow(at date: Date = Date()) -> Bool {
        guard let after = stage.slowNoteAfter else { return false }
        return date.timeIntervalSince(started) >= after
    }

    /// Whether to say the launch may have failed: past the stage's
    /// `possibleFailureAfter`, and quiet for its `stallAfter`.
    func mayHaveFailed(at date: Date = Date()) -> Bool {
        let factor = heavyLoad && stage.slowsUnderLoad ? LoadingStage.heavyLoadFactor : 1
        guard let after = stage.possibleFailureAfter, date.timeIntervalSince(started) >= after * factor else { return false }
        guard let quiet = stage.stallAfter else { return true }
        return date.timeIntervalSince(lastProgress) >= quiet * factor
    }
}
