//
//  WrappLock.swift
//  WrappFormat
//
//  What a wrapp was built from, recorded in it.

import Foundation
import WrappModules

/// What a wrapp was built from: its bundle and that bundle's version, the
/// edition, the modules and the release of each, and the Second Chance that
/// built it (`Contents/Resources/WrappLock.json`). Updating a wrapp works
/// out what to do from it; logs and reports say it. A wrapp built before
/// locks has none, and one is made up for it from its settings when needed.
nonisolated public struct WrappLock: Codable, Sendable, Equatable {
    /// A newer format than this reads is read as far as it can be.
    public var format: Int = 1
    public var bundle: BundleRef
    public var edition: String
    /// Where the edition came from: `disk`, `her-download`, `steam`.
    public var source: String
    public var composition: Composition
    public var modules: [ModuleRef]
    /// The version of Second Chance that built it.
    public var builtBy: String
    /// The revision of the launcher it carries (the template's
    /// `SecondChanceLauncherRevision`): a hash of the sources the wrapp's
    /// own code is built from. Nil for a wrapp from before it was recorded,
    /// whose launcher counts as out of date.
    public var launcher: String?
    /// The bundle ids this program's wrapps had before, whose folders are
    /// moved into this one's (`UserFilesMove`).
    public var formerBundleIDs: [String]?
    /// The variant's volumes, with the patterns a file of the person's in
    /// each matches.
    public var volumes: [VolumeRule]?
    /// The volume the game keeps its saves in, which the old folders become
    /// links to; nil keeps everything loose in the wrapp's folder, as a
    /// wrapp built before volumes did.
    public var savesVolume: String?
    /// The volume ScummVM's settings file is kept in, for a ScummVM game.
    public var scummvmSettingsVolume: String?
    /// The Wrappfile's global `ARG`s as the build had them (`install-dir`),
    /// which an update must find unchanged or move the program for.
    public var args: [String: String]?
    /// How this wrapp was updated from an older one; nil for a fresh build.
    public var updated: UpdateRecord?
    /// A lock made up for a wrapp built before locks, from its settings.
    public var madeUp: Bool?
    public var builtAt: Date

    public struct BundleRef: Codable, Sendable, Equatable {
        /// `nancy-drew/blue-moon`.
        public var id: String
        public var version: Int

        public init(id: String, version: Int) {
            self.id = id
            self.version = version
        }
    }

    public struct ModuleRef: Codable, Sendable, Equatable {
        public var id: String
        public var release: Int
        /// The version the build used, as `USE` resolved it.
        public var version: String?
        /// The SHA-256 of each of the module's data files the build read
        /// (`prefix.yaml`), which a module's default update compares.
        public var files: [String: String]?
        /// An engine's: its package's prepared hash, which names the engine
        /// the wrapp holds.
        public var package: String?

        public init(id: String, release: Int, version: String?, files: [String: String]? = nil, package: String? = nil) {
            self.id = id
            self.release = release
            self.version = version
            self.files = files
            self.package = package
        }
    }

    /// The updates that brought a wrapp here, and what it was before them:
    /// "updated from bundle 3 and wine 9.0_2 by from-wine-9, then taffy-patch".
    public struct UpdateRecord: Codable, Sendable, Equatable {
        public var fromBundle: Int
        public var fromModules: [ModuleRef]
        /// Each update that ran, in order; empty when the old wrapp's files
        /// were carried into this Second Chance's with nothing else to do.
        public var applied: [String]
        public var fromBuiltBy: String

        public init(fromBundle: Int, fromModules: [ModuleRef], applied: [String], fromBuiltBy: String) {
            self.fromBundle = fromBundle
            self.fromModules = fromModules
            self.applied = applied
            self.fromBuiltBy = fromBuiltBy
        }
    }

    public init(bundle: BundleRef, edition: String, source: String, composition: Composition,
                modules: [ModuleRef], builtBy: String, builtAt: Date = Date(),
                formerBundleIDs: [String]? = nil, volumes: [VolumeRule]? = nil, savesVolume: String? = nil,
                scummvmSettingsVolume: String? = nil) {
        self.bundle = bundle
        self.edition = edition
        self.source = source
        self.composition = composition
        self.modules = modules
        self.builtBy = builtBy
        self.builtAt = builtAt
        self.formerBundleIDs = formerBundleIDs
        self.volumes = volumes
        self.savesVolume = savesVolume
        self.scummvmSettingsVolume = scummvmSettingsVolume
    }

    /// The lock a wrapp built before locks would have had, made up from its
    /// settings and its Wine engine's version file, at bundle version 0:
    /// enough for an update to work out what it needs. `program` and
    /// `edition` are the caller's, which knows its bundles.
    public static func madeUp(settings: WrappSettings, program: String, edition: String,
                              wineVersion: String?, builtAt: Date = Date()) -> WrappLock {
        let composition = settings.composition
        let modules = composition.modules.map { module in
            ModuleRef(id: module.rawValue, release: 0, version: module == .wine ? wineVersion : nil)
        }
        // The game's folder, as the global ARG writes it: C:/… with the
        // exe's name dropped. ScummVM's exe path is the folder already.
        var installDir = settings.gameExePath
        if composition.has(.wine), let slash = installDir.lastIndex(of: "/") { installDir = String(installDir[..<slash]) }
        let args = composition.has(.wine) && !installDir.isEmpty ? ["install-dir": "C:" + installDir] : nil
        var lock = WrappLock(bundle: .init(id: program, version: 0), edition: edition,
                             source: (settings.source ?? .disk).rawValue, composition: composition,
                             modules: modules, builtBy: "unknown", builtAt: builtAt)
        lock.args = args
        lock.madeUp = true
        return lock
    }

    /// `10.0_8` from a Wine engine's version file ("wine sikarugir 10.0
    /// (revision 8)"), the way the wine module writes its versions; nil
    /// when there is no number in it.
    public static func wineVersion(fromVersionFile text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let number = words.first(where: { $0.first?.isNumber == true && $0.allSatisfy { $0.isNumber || $0 == "." } }) else {
            return nil
        }
        if let index = words.firstIndex(of: "(revision"), index + 1 < words.count {
            let revision = words[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: ")"))
            if Int(revision) != nil { return "\(number)_\(revision)" }
        }
        return number
    }

    /// The bundle id a wrapp of `program` (`nancy-drew/blue-moon`) has.
    public static func wrappBundleID(program: String) -> String {
        "au.gare.callum.second-chance.program." + program.replacingOccurrences(of: "/", with: ".")
    }

    /// This wrapp's bundle id.
    public var wrappBundleID: String { Self.wrappBundleID(program: bundle.id) }

    /// The lock of the wrapp at `layout`; nil for a wrapp built before locks.
    public init?(of layout: WrappLayout) throws {
        guard FileManager.default.fileExists(atPath: layout.lockFile.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(Self.self, from: Data(contentsOf: layout.lockFile))
    }

    public func write(to layout: WrappLayout) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: layout.resources, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: layout.lockFile)
    }

    /// For logs: "nancy-drew/blue-moon 1 (cd), wine 10.0_8 (release 1), …".
    public var summary: String {
        "\(bundle.id) \(bundle.version) (\(edition)), "
            + modules.map { "\($0.id)\($0.version.map { " \($0)" } ?? "") (release \($0.release))" }.joined(separator: ", ")
    }
}
