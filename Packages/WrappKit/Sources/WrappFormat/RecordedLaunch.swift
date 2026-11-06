//
//  RecordedLaunch.swift
//  WrappFormat
//
//  How a wrapp starts its program, as its Wrappfile's LAUNCHes said when
//  it was built.

import Foundation
import GameCatalog
import KeyNotation
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
    /// `--wine.mouse=grab-early`, whose wrapp works it out as it did then;
    /// `currentFormat` for one that says it.
    public var format: Int?
    /// The module that starts it, which the build worked out from the path
    /// type that claimed its program: nil for one recorded before it was
    /// (its program's prefix says, `launcher()`), and for a bare program in
    /// the app, which the core starts.
    public var module: ModuleID?

    /// The format a build records now.
    public static let currentFormat = 2

    private enum CodingKeys: String, CodingKey {
        case program, arguments, environment, options, fallback, mounts, format, module, volumes
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
        module = try container.decodeIfPresent(ModuleID.self, forKey: .module)
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
        try container.encodeIfPresent(module, forKey: .module)
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
                format: Int? = nil, module: ModuleID? = nil) {
        self.format = format
        self.module = module
        self.program = program
        self.arguments = arguments
        self.environment = environment
        self.options = options
        self.fallback = fallback
        self.mounts = mounts
    }

    /// The module that starts it: as the build recorded, else, for a launch
    /// recorded before it was, its program's prefix, which every type then
    /// was named after its module by (`wine:`, `scummvm:`, `steam://`). Nil
    /// for a bare program in the app, which the core starts.
    public func launcher() -> ModuleID? {
        if let module { return module }
        return Self.prefix(of: program).map { ModuleID(rawValue: $0) }
    }

    /// The program without its type's prefix: `C:/Nancy Drew/Game.exe`.
    public var path: String {
        guard let prefix = Self.prefix(of: program) else { return program }
        return String(program.dropFirst(prefix.count + 1))
    }

    /// A full form's type, before its colon; nil for a bare path, or a
    /// one-letter one, which is a drive.
    static func prefix(of fullForm: String) -> String? {
        guard let colon = fullForm.firstIndex(of: ":") else { return nil }
        let prefix = String(fullForm[..<colon])
        return prefix.count > 1 && !prefix.contains("/") ? prefix : nil
    }

    /// The program the launch starts: a launcher names it in an option of
    /// its own (`--steam.exe`, `--big-fish.exe`), else it's the program.
    public var startedProgram: String { options["steam.exe"] ?? options["big-fish.exe"] ?? program }

    /// The started program's path from its drive's root (`/Nancy Drew/Game.exe`),
    /// which older settings name it by, as its module says (`places`); nil
    /// for one on no drive (a ScummVM game's folder, `steam://`).
    public func legacyProgramPath(places: PathPlaces) -> String? {
        places.legacyProgramPath(of: startedProgram)
    }

    /// What the build's events name the program by: its path from its
    /// drive's root, else the path without its type (a folder without its
    /// last slash: `/SharedSupport/game`).
    public func shownPath(places: PathPlaces) -> String {
        if let legacy = legacyProgramPath(places: places) { return legacy }
        let path = startedProgram == program ? self.path : startedProgram
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
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
                || mount.options["dosbox.overlay"] != nil || mount.target == "basilisk:disk/"
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

    /// `--wine.quit-key=<keys>`, as written: the keys the app's Quit
    /// presses in a program that ignores Wine's quit but quits on a key of
    /// its own (docs/wrappfile.md#key-sequences).
    public var quitKey: String? { options["wine.quit-key"] }

    /// `--wine.quit-confirm-key=<keys>`, as written: the keys a second Quit
    /// soon after the first presses, for a program whose quit key asks first
    /// (Icy Tower's Escape); the first Quit then presses the quit key alone.
    public var quitConfirmKey: String? { options["wine.quit-confirm-key"] }

    /// How long the quit watch leaves from one quit key's release to the
    /// next's press, unless the keys say (`gap=`, `wait=`): long enough for
    /// a game to have changed screens before the next. Icy Tower's menu,
    /// back from a game, takes over 1.2 s to read keys again; 2.5 s does.
    /// The canonical form the helper is handed spells it out
    /// (`KeySequence.canonical(defaultGapMilliseconds:)`).
    public static let quitKeyGapMilliseconds = 2500

    /// The quit keys, as the quit watch is to press them; nil without any.
    /// Throws for keys planning would have refused.
    public func quitKeySequence() throws(KeySequence.ParseError) -> KeySequence? {
        guard let written = quitKey, !written.isEmpty else { return nil }
        return try KeySequence(parsing: written)
    }

    /// The confirm keys, as the quit watch is to press them; nil without
    /// any, or without quit keys.
    public func quitConfirmKeySequence() throws(KeySequence.ParseError) -> KeySequence? {
        guard !(quitKey ?? "").isEmpty, let written = quitConfirmKey, !written.isEmpty else { return nil }
        return try KeySequence(parsing: written)
    }

    /// `--wine.fullscreen-setting=…`: where the program keeps its own
    /// fullscreen setting, which the wrapp sets to the player's choice when
    /// they last changed it with the window's fullscreen button. Nil when
    /// the launch names none, or one planning would have refused.
    public var fullscreenSetting: FullscreenSetting? {
        options[FullscreenSetting.option].flatMap { try? FullscreenSetting(parsing: $0) }
    }

    /// Whether the wrapp arms cursor lock: when its launch says
    /// `--wine.mouse=grab-early`, or, recorded before it could, when the program
    /// may draw through cnc-ddraw (`inferred`).
    public func cursorLock(inferred: Bool) -> Bool {
        choosesItsHelpers ? options["wine.mouse"] == "grab-early" : inferred
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
        // A bare program in the app: the core starts it.
        case let launcher: self.init(launcher: launcher)
        }
    }
}
