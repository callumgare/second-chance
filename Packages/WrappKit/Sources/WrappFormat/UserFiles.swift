//
//  UserFiles.swift
//  WrappFormat
//
//  Where a wrapp keeps what's the person's, and moving it there from where
//  wrapps with an earlier bundle id kept it.

import Foundation

/// Everything a wrapp keeps of its own outside itself, in one folder named by
/// its bundle id, as a Mac app does:
///
/// ```text
/// <Application Support>/<bundle id>/
///   stores/<owner>/<name>/  one folder per kept store of the app's
///                           (`app` for the Wrappfile's own, a module's id
///                           for a module's): the person's files, and the
///                           program's own settings beside them
///   wrapp-settings/         Second Chance's settings for the wrapp
/// ```
///
/// Before stores, an app's own were `volumes/<name>/`, which
/// `moveVolumesIntoStores` renames.
///
/// `appSupport` is `~/Library/Application Support`, or what
/// `SECOND_CHANCE_APP_SUPPORT_DIR` names in its place, so a test never
/// touches a player's files.
nonisolated public struct UserFilesLayout: Sendable, Equatable {
    public let appSupport: URL
    public let bundleID: String

    public init(appSupport: URL, bundleID: String) {
        self.appSupport = appSupport
        self.bundleID = bundleID
    }

    /// The real Application Support folder, or the one the environment names
    /// in its place.
    public static func appSupport(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["SECOND_CHANCE_APP_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    public var folder: URL { appSupport.appendingPathComponent(bundleID, isDirectory: true) }
    /// One of the app's own kept stores, by its name (`wine-documents`).
    public func volume(_ name: String) -> URL { store(owner: "app", name: name) }

    /// A kept store of the app's, by owner and name.
    public func store(owner: String, name: String) -> URL {
        folder.appendingPathComponent("stores", isDirectory: true).appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// `volumes/`, as a wrapp built before stores kept the app's own,
    /// renamed `stores/app/` if there's none yet. True when it moved.
    @discardableResult
    public func moveVolumesIntoStores() throws -> Bool {
        let volumes = folder.appendingPathComponent("volumes", isDirectory: true)
        let stores = folder.appendingPathComponent("stores/app", isDirectory: true)
        let files = FileManager.default
        guard files.fileExists(atPath: volumes.path), !files.fileExists(atPath: stores.path) else { return false }
        try files.createDirectory(at: stores.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: volumes, to: stores)
        return true
    }
    public var settings: URL { folder.appendingPathComponent("wrapp-settings", isDirectory: true) }

    /// The names of Second Chance's own settings files, which a wrapp kept
    /// loose in its folder before volumes and which go in `settings`.
    public static let settingsFileNames: Set<String> = ["dont-show-save-warning"]
}

/// A volume, as moving files into it needs to know it.
nonisolated public struct VolumeRule: Codable, Sendable, Equatable {
    public let name: String
    /// Globs (relative to the volume, case aside) a file of the person's
    /// matches; nil for any file.
    public let patterns: [String]?

    public init(name: String, patterns: [String]?) {
        self.name = name
        self.patterns = patterns
    }
}

/// Moves the folders wrapps with former bundle ids kept into this wrapp's
/// layout, and leaves each a link to the volume it was
/// (docs/wrapp-launch.md#user-files). Every launch and every build runs
/// it; with nothing to move it is one `lstat` per former id.
///
/// - The old folder's files go to the volume whose patterns they match,
///   Second Chance's settings files to `wrapp-settings/`, and the rest to
///   `linkVolume`, which the old folder becomes a link to.
/// - Nothing is half moved: a folder whose files all go to `linkVolume`
///   (an empty or missing one) is renamed whole; otherwise each file is
///   moved on its own and the folder replaced by the link once empty. A
///   marker in `wrapp-settings/` says a move began, so a run cut short
///   between the rename and the link only makes the link.
/// - Nothing is overwritten: a file whose name is taken stays, and the one
///   coming in is kept beside it under a dated name.
/// - One mover at a time (a lock file in Application Support), and never
///   while an app with the old or new id is running.
nonisolated public struct UserFilesMove: Sendable {
    public let layout: UserFilesLayout
    public let formerBundleIDs: [String]
    public let volumes: [VolumeRule]
    public let linkVolume: String

    public init(layout: UserFilesLayout, formerBundleIDs: [String], volumes: [VolumeRule], linkVolume: String) {
        self.layout = layout
        self.formerBundleIDs = formerBundleIDs
        self.volumes = volumes
        self.linkVolume = linkVolume
    }

    /// What a run did, for the log, and the files kept under another name.
    public struct Outcome: Sendable, Equatable {
        public var log: [String] = []
        /// Files that arrived where one of their name already was, by the
        /// name each was kept under.
        public var keptBeside: [String] = []
    }

    /// Move every former id's folder in. `isRunning` says whether an app
    /// with a bundle id is running.
    public func run(isRunning: (String) -> Bool, now: Date = Date()) -> Outcome {
        var outcome = Outcome()
        let files = FileManager.default
        for formerID in formerBundleIDs where formerID != layout.bundleID {
            let old = layout.appSupport.appendingPathComponent(formerID, isDirectory: true)
            let marker = layout.settings.appendingPathComponent("moved-from-\(formerID)")
            let kind = Self.kind(of: old)
            if kind == .missing, files.fileExists(atPath: marker.path) {
                // A run cut short after the rename: only the link is left.
                link(old, outcome: &outcome)
                continue
            }
            guard kind == .folder else { continue }
            if isRunning(formerID) || isRunning(layout.bundleID) {
                outcome.log.append("Not moving \(formerID)'s files now: a game with it is running")
                continue
            }
            guard let lock = Lock(at: layout.appSupport.appendingPathComponent(".second-chance-move.lock")) else {
                outcome.log.append("Not moving \(formerID)'s files now: another move is under way")
                continue
            }
            defer { lock.release() }
            do {
                try move(old, marker: marker, outcome: &outcome, now: now)
                link(old, outcome: &outcome)
            } catch {
                outcome.log.append("Moving \(formerID)'s files stopped, to carry on next time: \(error.localizedDescription)")
            }
        }
        return outcome
    }

    // MARK: - Moving

    /// What is at a path, not following a link.
    public enum Kind: Sendable { case missing, link, folder, other }

    public static func kind(of url: URL) -> Kind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .missing }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .link
        case S_IFDIR: return .folder
        default: return .other
        }
    }

    private func move(_ old: URL, marker: URL, outcome: inout Outcome, now: Date) throws {
        let files = FileManager.default
        try files.createDirectory(at: layout.settings, withIntermediateDirectories: true)
        try Data().write(to: marker)
        let destinations = try plan(old)
        let target = layout.volume(linkVolume)
        let allToLink = destinations.allSatisfy { $0.value == .settings || $0.value == .volume(linkVolume) }
        let linkEmpty = (try? files.contentsOfDirectory(atPath: target.path).isEmpty) ?? true
        // Second Chance's settings files leave first, whichever way the rest goes.
        for (relative, destination) in destinations.sorted(by: { $0.key < $1.key }) where destination == .settings {
            try moveFile(old.appendingPathComponent(relative), to: layout.settings.appendingPathComponent(relative),
                         outcome: &outcome, now: now)
        }
        if allToLink && linkEmpty {
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            try files.moveItem(at: old, to: target)
            outcome.log.append("Moved \(old.lastPathComponent) whole into stores/app/\(linkVolume)")
            return
        }
        for (relative, destination) in destinations.sorted(by: { $0.key < $1.key }) where destination != .settings {
            guard case .volume(let name) = destination else { continue }
            try moveFile(old.appendingPathComponent(relative), to: layout.volume(name).appendingPathComponent(relative),
                         outcome: &outcome, now: now)
        }
        try removeEmptyFolders(in: old)
        outcome.log.append("Moved \(old.lastPathComponent)'s files into \(layout.bundleID)'s volumes")
    }

    enum Destination: Equatable { case settings, volume(String) }

    /// Where each of the old folder's files goes, by its path in it.
    func plan(_ old: URL) throws -> [String: Destination] {
        var destinations: [String: Destination] = [:]
        let base = old.standardizedFileURL.path + "/"
        guard let walk = FileManager.default.enumerator(at: old, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return destinations
        }
        for case let file as URL in walk {
            guard Self.kind(of: file) != .folder else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(base.count))
            if !relative.contains("/"), UserFilesLayout.settingsFileNames.contains(relative) {
                destinations[relative] = .settings
            } else if let volume = volumes.first(where: { $0.name != linkVolume && Self.matches(relative, $0.patterns) }) {
                destinations[relative] = .volume(volume.name)
            } else {
                destinations[relative] = .volume(linkVolume)
            }
        }
        return destinations
    }

    static func matches(_ path: String, _ patterns: [String]?) -> Bool {
        guard let patterns else { return false }
        return patterns.contains { fnmatch($0.lowercased(), path.lowercased(), FNM_PATHNAME) == 0 }
    }

    /// Move one file, never over another: one whose name is taken is kept
    /// beside it as `<name> (from <date>).<ext>`.
    private func moveFile(_ source: URL, to destination: URL, outcome: inout Outcome, now: Date) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var target = destination
        if Self.kind(of: target) != .missing {
            target = Self.dated(destination, now: now)
            var counter = 2
            while Self.kind(of: target) != .missing {
                target = Self.dated(destination, now: now, counter: counter)
                counter += 1
            }
            outcome.keptBeside.append(target.lastPathComponent)
            outcome.log.append("Kept \(source.lastPathComponent) as \(target.lastPathComponent): \(destination.lastPathComponent) was already there")
        }
        try files.moveItem(at: source, to: target)
    }

    static func dated(_ url: URL, now: Date, counter: Int? = nil) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = " (from \(formatter.string(from: now))\(counter.map { " \($0)" } ?? ""))"
        let name = ext.isEmpty ? stem + suffix : "\(stem)\(suffix).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func removeEmptyFolders(in folder: URL) throws {
        let files = FileManager.default
        for item in try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where Self.kind(of: item) == .folder {
            try removeEmptyFolders(in: item)
        }
        let left = try files.contentsOfDirectory(atPath: folder.path).filter { $0 != ".DS_Store" }
        if left.isEmpty { try files.removeItem(at: folder) }
    }

    /// The old folder, as a link to `linkVolume`, once it's gone.
    private func link(_ old: URL, outcome: inout Outcome) {
        guard Self.kind(of: old) == .missing else {
            outcome.log.append("\(old.lastPathComponent) still has files in it; it'll be moved next time")
            return
        }
        do {
            try FileManager.default.createDirectory(at: layout.volume(linkVolume), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: old, withDestinationURL: layout.volume(linkVolume))
            outcome.log.append("Left \(old.lastPathComponent) as a link to \(layout.bundleID)/stores/app/\(linkVolume)")
        } catch {
            outcome.log.append("Couldn't leave \(old.lastPathComponent) as a link: \(error.localizedDescription)")
        }
    }

    /// A lock file made exclusively; one older than ten minutes is a mover
    /// that died, and is taken over.
    struct Lock {
        let url: URL

        init?(at url: URL) {
            self.url = url
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               Date().timeIntervalSince(modified) > 600 {
                try? FileManager.default.removeItem(at: url)
            }
            let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            guard descriptor >= 0 else { return nil }
            close(descriptor)
        }

        func release() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
