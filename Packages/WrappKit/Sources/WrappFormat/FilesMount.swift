//
//  FilesMount.swift
//  WrappFormat
//
//  A launch's `files=` mount: a store holding the files that sit beside a
//  program's own, in the folder it's in, as old games keep their settings
//  and high scores (decision 23 of the builders plan;
//  docs/wrappfile.md#the-launch-volumes-and-app).

import Darwin
import Foundation

/// The store's files linked into `folder` before the program starts, and
/// new ones moved into the store after it ends. Each file is matched by
/// name, in `folder` alone (not its subfolders), against `patterns`.
nonisolated public struct FilesMount: Sendable, Equatable {
    /// The folder in the app the program sees the files in.
    public let folder: URL
    /// The store's folder.
    public let store: URL
    /// Shell-style patterns of the names that are the store's: `LaserTank.ini`, `*.hs`.
    public let patterns: [String]

    public init(folder: URL, store: URL, patterns: [String]) {
        self.folder = folder
        self.store = store
        self.patterns = patterns
    }

    /// The `files=` mounts `launch` records, in the app at `app`, each
    /// with the app's own store of its name in `userFiles`. One whose
    /// target has no place in the app is left out (the build checks it
    /// has, `WrappBuildHelper.checkLaunchMounts`).
    public static func mounts(of launch: RecordedLaunch, app: WrappLayout, userFiles: UserFilesLayout) -> [FilesMount] {
        launch.mounts.compactMap { mount in
            guard let patterns = mount.filePatterns, let folder = app.location(mount.target) else { return nil }
            let owner = String(mount.store.prefix { $0 != ":" })
            return FilesMount(folder: folder, store: userFiles.store(owner: owner, name: mount.name), patterns: patterns)
        }
    }

    /// `files=`'s value split into its patterns: `;`-separated.
    public static func patterns(_ value: String) -> [String] {
        value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whatever its case, as Windows matches names.
    public func matches(_ name: String) -> Bool {
        patterns.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 }
    }

    /// Before the program starts. A file in the folder that isn't a link
    /// is moved into the store when the store has none of that name (the
    /// build's default, so the person's copy starts from it), or when it
    /// was written after the store's (the game wrote it afresh and ended
    /// before `collect` could keep it); otherwise the store's wins. A link
    /// into another store (the app run with another, which a test's own
    /// store, since removed, leaves behind) is replaced, its file copied in
    /// first when it is still there and the store has none of that name, as
    /// a link to nothing leaves the program unable to write its file. Then
    /// each of the store's files is linked into the folder. Returns what it
    /// did, for the log.
    @discardableResult
    public func connect() throws -> [String] {
        let files = FileManager.default
        try files.createDirectory(at: store, withIntermediateDirectories: true)
        var done: [String] = []
        for name in try names(in: folder) where matches(name) && !isLink(folder.appendingPathComponent(name)) {
            let inStore = store.appendingPathComponent(name), inFolder = folder.appendingPathComponent(name)
            if files.fileExists(atPath: inStore.path), modified(inStore) >= modified(inFolder) {
                try files.removeItem(at: inFolder)
                done.append("the store's \(name) replaces the app's")
            } else {
                if files.fileExists(atPath: inStore.path) { try files.removeItem(at: inStore) }
                try files.moveItem(at: inFolder, to: inStore)
                done.append("moved the app's \(name) into the store")
            }
        }
        for name in try names(in: folder) where matches(name) && isLink(folder.appendingPathComponent(name)) {
            let link = folder.appendingPathComponent(name), inStore = store.appendingPathComponent(name)
            guard let destination = try? files.destinationOfSymbolicLink(atPath: link.path), destination != inStore.path else { continue }
            if !files.fileExists(atPath: inStore.path), files.fileExists(atPath: destination) {
                try files.copyItem(at: URL(fileURLWithPath: destination), to: inStore)
                done.append("copied \(name) from the store its link led to")
            } else {
                done.append("removed \(name)'s link to another store")
            }
            try files.removeItem(at: link)
        }
        for name in try names(in: store) where matches(name) {
            let link = folder.appendingPathComponent(name)
            let target = store.appendingPathComponent(name)
            if (try? files.destinationOfSymbolicLink(atPath: link.path)) == target.path { continue }
            if isLink(link) || files.fileExists(atPath: link.path) { try files.removeItem(at: link) }
            try files.createSymbolicLink(at: link, withDestinationURL: target)
            done.append("linked \(name)")
        }
        return done
    }

    /// After the program ends: each file in the folder that matches and
    /// isn't a link, one the program made or wrote afresh, is moved into
    /// the store and left as a link. Safe to call more than once.
    @discardableResult
    public func collect() throws -> [String] {
        let files = FileManager.default
        guard files.fileExists(atPath: folder.path) else { return [] }
        try files.createDirectory(at: store, withIntermediateDirectories: true)
        var done: [String] = []
        for name in try names(in: folder) where matches(name) {
            let file = folder.appendingPathComponent(name)
            guard !isLink(file), !isFolder(file) else { continue }
            let inStore = store.appendingPathComponent(name)
            if files.fileExists(atPath: inStore.path) { try files.removeItem(at: inStore) }
            try files.moveItem(at: file, to: inStore)
            try files.createSymbolicLink(at: file, withDestinationURL: inStore)
            done.append("kept \(name)")
        }
        return done
    }

    private func names(in url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private func modified(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    private func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }
}
