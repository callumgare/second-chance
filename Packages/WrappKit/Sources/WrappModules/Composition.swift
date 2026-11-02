//
//  Composition.swift
//  WrappModules
//
//  Which modules a wrapp runs: one that starts the program, and the
//  services started before it.

import Foundation
import GameCatalog

/// A module's id: `wine`, `scummvm`, `steam`, `big-fish`, and later any module a bundle
/// uses. Each of a module's facets (what it does in a build, in the wrapp,
/// in a test) is found by it.
nonisolated public struct ModuleID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible,
    ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let wine: ModuleID = "wine"
    public static let scummvm: ModuleID = "scummvm"
    public static let steam: ModuleID = "steam"
    public static let bigFish: ModuleID = "big-fish"
}

/// What a wrapp runs: the one module that starts the program (its
/// launcher), and the services started before it, in order, and stopped in
/// the reverse. Everything that would ask "is this a Wine game?" asks the
/// composition whether it has a module instead, so a module added later is
/// asked about the same way.
///
/// Today's four engines are three compositions: Wine or ScummVM alone, Wine
/// with Steam running beside it, or Steam starting the game in Wine. One
/// more, Big Fish's DRM starting the game in Wine, is written as the Wine
/// engine with the game's `.bfg` beside it (`WrappSettings.bigFishLaunchFile`).
nonisolated public struct Composition: Codable, Sendable, Hashable, CustomStringConvertible {
    public var launcher: ModuleID
    /// In start order.
    public var services: [ModuleID]

    public init(launcher: ModuleID, services: [ModuleID] = []) {
        self.launcher = launcher
        self.services = services
    }

    /// The modules each one needs running with it: Steam and Big Fish's
    /// programs run in Wine.
    static let dependencies: [ModuleID: [ModuleID]] = [.steam: [.wine], .bigFish: [.wine]]

    /// Every module the wrapp runs: its services, its launcher, and what
    /// each of them needs, each once.
    public var modules: [ModuleID] {
        var all: [ModuleID] = []
        func add(_ module: ModuleID) {
            guard !all.contains(module) else { return }
            for dependency in Self.dependencies[module] ?? [] { add(dependency) }
            all.append(module)
        }
        (services + [launcher]).forEach(add)
        return all
    }

    /// Whether the wrapp runs `module`, as its launcher, a service or what
    /// either needs.
    public func has(_ module: ModuleID) -> Bool { modules.contains(module) }

    public var description: String {
        services.isEmpty ? launcher.rawValue : "\(launcher.rawValue) with \(services.map(\.rawValue).joined(separator: ", "))"
    }

    // MARK: - Today's engines

    /// The composition a wrapp with `engine` runs: how a wrapp built before
    /// compositions is read.
    public init(legacy engine: GameInfo.GameEngine) {
        switch engine {
        case .wine: self.init(launcher: .wine)
        case .scummvm: self.init(launcher: .scummvm)
        case .wineSteamSilent: self.init(launcher: .wine, services: [.steam])
        case .wineSteam: self.init(launcher: .steam, services: [.steam])
        }
    }

    /// The engine this composition was, while compositions have one: what
    /// is written to a wrapp's settings for older readers, sent as failure
    /// reports' `engine` tag, and published in the build's `engineRouted`
    /// event, so all three read as they did. Nil for a composition today's
    /// engines can't express.
    public var legacyEngine: GameInfo.GameEngine? {
        // Big Fish's is a Wine game to older readers, as it always was.
        if self == Composition(launcher: .bigFish) { return .wine }
        return GameInfo.GameEngine.allCases.first { Composition(legacy: $0) == self }
    }

    /// The `engine` tag reports and the integration tests' events carry:
    /// today's engine's name, or for a composition with none, its
    /// launcher's id.
    public var engineTag: String { legacyEngine?.rawValue ?? launcher.rawValue }
}

nonisolated extension GameInfo {
    /// The modules a wrapp of this game runs, built from a disc or a
    /// download (a Steam build works its own out: `steamEngine`).
    public var composition: Composition { Composition(legacy: gameEngine) }
}
