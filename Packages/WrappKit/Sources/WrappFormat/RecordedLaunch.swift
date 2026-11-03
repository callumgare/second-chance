//
//  RecordedLaunch.swift
//  WrappFormat
//
//  How a wrapp starts its program, as its Wrappfile's LAUNCH and VOLUMEs
//  said when it was built.

import Foundation
import GameCatalog
import WrappModules

/// What a wrapp runs, recorded by the build from its plan
/// (docs/wrappfile.md#launch): the program in its full form, which says the
/// module that starts it, its arguments, environment and module options,
/// the program to fall back to, and the volumes it sees. The wrapp reads
/// this, never Wrappfile syntax; a wrapp built before it was recorded has
/// one made from its legacy settings (`WrappSettings.launch`).
nonisolated public struct RecordedLaunch: Codable, Sendable, Equatable {
    /// In full form: `wine:C:/Nancy Drew/Game.exe`, `scummvm:/SharedSupport/game/`,
    /// `dosbox:C:/TYRIAN/TYRIAN2K.EXE`, `steam://rungameid/572740`.
    public var program: String
    public var arguments: [String]
    /// `--env NAME=<value>`, by name.
    public var environment: [String: String]
    /// Its modules' options, by `<module id>.<option>`: `wine.graphics`.
    public var options: [String: String]
    /// The program offered when the launch fails or seems stuck, in full form.
    public var fallback: String?
    /// The volumes the program sees, in order.
    public var volumes: [Volume]

    /// One of the bundle's volumes, where the program sees it.
    public struct Volume: Codable, Sendable, Equatable {
        public var name: String
        /// In full form: `wine:C:/users/crossover/Documents`, `scummvm:saves/`.
        public var location: String
        /// Its modules' options: `wine.drive`, `dosbox.overlay`.
        public var options: [String: String]

        public init(name: String, location: String, options: [String: String] = [:]) {
            self.name = name
            self.location = location
            self.options = options
        }
    }

    public init(program: String, arguments: [String] = [], environment: [String: String] = [:],
                options: [String: String] = [:], fallback: String? = nil, volumes: [Volume] = []) {
        self.program = program
        self.arguments = arguments
        self.environment = environment
        self.options = options
        self.fallback = fallback
        self.volumes = volumes
    }

    /// The module that starts it: its program's path type's.
    public func launcher(_ types: PathTypeRegistry = .shipped) -> ModuleID? {
        types.split(program)?.type.module
    }

    /// The program without its type's prefix: `C:/Nancy Drew/Game.exe`.
    public var path: String {
        PathTypeRegistry.shipped.split(program)?.rest ?? program
    }

    /// What a Wine program draws with, as its launch declares
    /// (`--wine.graphics`): nil for one that declares nothing, or `unknown`.
    public var graphics: GameInfo.Graphics? {
        switch options["wine.graphics"] {
        case "direct-draw": .directDraw
        case "direct-3d": .direct3D
        default: nil
        }
    }

    /// The volume a module keeps the person's saves in: Wine's at the
    /// Documents folder, ScummVM's `saves/`, DOSBox's overlay.
    public var savesVolume: String? {
        volumes.first { volume in
            volume.location.hasPrefix("wine:C:/users/") || volume.location == "scummvm:saves/"
                || volume.options["dosbox.overlay"] != nil
        }?.name
    }

    /// The volume ScummVM keeps its settings in, `scummvm:settings/`.
    public var scummvmSettingsVolume: String? {
        volumes.first { $0.location == "scummvm:settings/" }?.name
    }
}

nonisolated extension Composition {
    /// The modules a wrapp runs for `launch`: its program's module, and
    /// Steam's running beside a game Steam starts.
    public init(launch: RecordedLaunch) {
        switch launch.launcher() {
        case .steam?: self.init(launcher: .steam, services: [.steam])
        case let launcher?: self.init(launcher: launcher)
        case nil: self.init(launcher: .wine)
        }
    }
}
