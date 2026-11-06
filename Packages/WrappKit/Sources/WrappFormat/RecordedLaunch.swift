//
//  RecordedLaunch.swift
//  WrappFormat
//
//  How a wrapp starts its program, as its Wrappfile's LAUNCHes said when
//  it was built.

import Foundation
import GameCatalog
import WrappModules

/// What a wrapp runs, recorded by the build from its plan
/// (docs/wrappfile.md#launch): the program in its full form, which says the
/// module that starts it, its arguments, environment and module options,
/// the program to fall back to, and the stores it sees. The wrapp reads
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
    /// The stores the program sees, where it sees them, in order.
    public var mounts: [Mount]
    /// What the launch says for itself: nil (1) for one recorded before
    /// `--wine.cursor-lock`, whose wrapp works it out as it did then;
    /// `currentFormat` for one that says it.
    public var format: Int?

    /// The format a build records now.
    public static let currentFormat = 2

    private enum CodingKeys: String, CodingKey {
        case program, arguments, environment, options, fallback, mounts, format, volumes
    }

    /// A launch a build before stores recorded (unreleased, but in apps built
    /// from that code): its `volumes`, each the app's own store of its name
    /// at its location, and at its Wine drive too (`wine.drive`), as
    /// `wrapp-builder fmt --migrate` rewrites a `VOLUME`.
    private struct Volume: Decodable {
        var name: String
        var location: String
        var options: [String: String]?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        program = try container.decode(String.self, forKey: .program)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        options = try container.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
        fallback = try container.decodeIfPresent(String.self, forKey: .fallback)
        format = try container.decodeIfPresent(Int.self, forKey: .format)
        if let mounts = try container.decodeIfPresent([Mount].self, forKey: .mounts) {
            self.mounts = mounts
        } else {
            mounts = try (container.decodeIfPresent([Volume].self, forKey: .volumes) ?? []).flatMap { volume -> [Mount] in
                var options = volume.options ?? [:]
                let drive = options.removeValue(forKey: "wine.drive")
                let store = "app:\(volume.name)"
                return (drive.map { [Mount(store: store, target: "wine:" + $0)] } ?? []) + [Mount(store: store, target: volume.location, options: options)]
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(program, forKey: .program)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(environment, forKey: .environment)
        try container.encode(options, forKey: .options)
        try container.encodeIfPresent(fallback, forKey: .fallback)
        try container.encode(mounts, forKey: .mounts)
        try container.encodeIfPresent(format, forKey: .format)
    }

    /// A store, where the program sees it
    /// (`LAUNCH --mount=type=store,source=<store>,target=<path>`).
    public struct Mount: Codable, Sendable, Equatable {
        /// By its full name: `app:wine-documents`, `steam:sign-in`.
        public var store: String
        /// In full form: `wine:A:`, `wine:C:/users/crossover/Documents`, `scummvm:saves/`.
        public var target: String
        /// Its modules' fields: `dosbox.overlay`.
        public var options: [String: String]

        public init(store: String, target: String, options: [String: String] = [:]) {
            self.store = store
            self.target = target
            self.options = options
        }

        /// The store's own name, without its owner: what an app's own
        /// store's folder, and the manifest's `volumes:`, call it.
        public var name: String { store.split(separator: ":", maxSplits: 1).last.map(String.init) ?? store }

        /// A `files=` mount's patterns: the names in the target folder that
        /// are the store's (`FilesMount`). Nil for a mount of the whole store.
        public var filePatterns: [String]? { options["files"].map(FilesMount.patterns) }

        /// The Wine drive it's mounted as (`wine:A:`), in lower case.
        public var wineDrive: Character? {
            guard target.count == 7, target.hasPrefix("wine:"), target.hasSuffix(":") else { return nil }
            return target.dropFirst(5).first.map { Character($0.lowercased()) }
        }
    }

    public init(program: String, arguments: [String] = [], environment: [String: String] = [:],
                options: [String: String] = [:], fallback: String? = nil, mounts: [Mount] = [],
                format: Int? = nil) {
        self.format = format
        self.program = program
        self.arguments = arguments
        self.environment = environment
        self.options = options
        self.fallback = fallback
        self.mounts = mounts
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

    /// The store a module keeps the person's saves in, by its own name:
    /// Wine's at the Documents folder, ScummVM's `saves/`, DOSBox's overlay.
    public var savesVolume: String? {
        mounts.first { mount in
            mount.target.hasPrefix("wine:C:/users/") || mount.target == "scummvm:saves/"
                || mount.options["dosbox.overlay"] != nil
        }?.name
    }

    /// Whether it says whether it wants the cursor lock: one recorded
    /// before it could has its lock worked out from the program, as every
    /// wrapp did then.
    public var choosesItsHelpers: Bool { (format ?? 1) >= 2 }

    /// `--wine.window=windowed`: a Wine program stays in its window,
    /// whatever it asks for; an override for one the wrapp gets wrong
    /// (decision 27 of the builders plan).
    public var keepsWindowed: Bool { options["wine.window"] == "windowed" }

    /// `--wine.window=fullscreen`: a Wine program's window is made
    /// fullscreen whether or not it asks to be.
    public var forcesFullscreen: Bool { options["wine.window"] == "fullscreen" }

    /// `--wine.quit-key=<key>`: the key the app's Quit holds down in a
    /// program that ignores Wine's quit but quits on a key of its own.
    public var quitKey: String? { options["wine.quit-key"] }

    /// `--wine.quit-confirm-key=<keys>`: the keys a second Quit soon after
    /// the first presses, for a program whose quit key asks first (Icy
    /// Tower's Escape); the first Quit then presses the quit key alone.
    public var quitConfirmKey: String? { options["wine.quit-confirm-key"] }

    /// Whether the wrapp arms cursor lock: when its launch says
    /// `--wine.cursor-lock`, or, recorded before it could, when the program
    /// may draw through cnc-ddraw (`inferred`).
    public func cursorLock(inferred: Bool) -> Bool {
        choosesItsHelpers ? options["wine.cursor-lock"] != nil : inferred
    }

    /// The store ScummVM keeps its settings in, `scummvm:settings/`.
    public var scummvmSettingsVolume: String? {
        mounts.first { $0.target == "scummvm:settings/" }?.name
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
