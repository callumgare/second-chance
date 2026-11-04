//
//  LayerCachePolicy.swift
//  SecondChance
//
//  Which layers a build keeps, as `SECOND_CHANCE_LAYER_CACHE` says.

import Foundation
import SecondChanceKit
import WrappBuilder

/// What a build caches as layers (docs/wrapp-build.md#the-layer-cache):
/// `SECOND_CHANCE_LAYER_CACHE` (`sc … --debug layer-cache=<policy>`), else
/// everything, but only the prefix under test, so an integration run
/// installs every game for real.
nonisolated enum LayerCachePolicy: String, Sendable {
    /// Nothing: every build makes its own prefix and installs.
    case off
    /// The new Wine prefix alone.
    case prefix
    /// The prefix and the installed game.
    case all

    /// As the runner's policy: `prefix` is its `modules`.
    nonisolated var runnerPolicy: LayerPolicy {
        switch self {
        case .all: .all
        case .prefix: .modules
        case .off: .off
        }
    }

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> LayerCachePolicy {
        if let value = environment["SECOND_CHANCE_LAYER_CACHE"], let policy = LayerCachePolicy(rawValue: value) {
            return policy
        }
        return TestHost.isRunning ? .prefix : .all
    }
}
