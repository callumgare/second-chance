//
//  CiderPackage.swift
//  SecondChance
//
//  A Her Interactive Mac download: a disk image holding TransGaming's Cider
//  installer, whose payload is a finished Cider app with the installed
//  Windows game inside it.
//

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.CiderPackage")
private nonisolated let tarLogger = Logger(label: "au.gare.callum.second-chance.SecondChance.tar")

/// A mounted Her Interactive Mac download made with TransGaming's Cider.
///
/// Cider is a Wine fork, and the app it builds keeps the game exactly as the
/// Windows installer left it, in `Contents/Resources/transgaming/c_drive`.
/// The 32-bit Cider runtime no longer starts on macOS, but the game inside
/// it is the Windows release, so a wrapp takes the game's folder and leaves
/// the rest behind. From Cider's own `system32` it takes only the DLLs Wine
/// doesn't provide itself (the MFC runtimes a disc's installer would have
/// installed): the rest, `ddraw.dll` and `d3d9.dll` among them, would replace
/// cnc-ddraw and Wine's builtins.
///
/// The image's layout ([docs/her-download.md](../../docs/her-download.md)):
///
/// ```
/// <volume>/<Game> Installer.app/Contents/Resources/tgInstall.plist
/// <volume>/installer/INSTALLDATA.tgz            the Cider app, as output.app
/// <volume>/installer/INSTALLDATA.tgz.manifest   one line per entry
/// ```
nonisolated struct CiderPackage {
    let volume: URL
    let volumeName: String
    /// `InstallGame` in `tgInstall.plist`: the game's title.
    let gameName: String?
    /// `ForbiddenGameID`: the Cider app's bundle id, `com.transgaming.nancydrew…`.
    let bundleIdentifier: String?
    let payload: URL
    let manifest: URL?

    /// Thrown by `init(volume:)` for an image that isn't a Cider installer.
    struct NotCider: Error, CustomStringConvertible {
        let description: String
    }

    /// Recognise a mounted image as a Cider installer.
    init(volume: URL) throws {
        let fileManager = FileManager.default
        self.volume = volume
        volumeName = volume.lastPathComponent

        let payload = volume.appendingPathComponent("installer/INSTALLDATA.tgz")
        guard fileManager.fileExists(atPath: payload.path) else {
            throw NotCider(description: "it has no installer/INSTALLDATA.tgz")
        }
        self.payload = payload
        let manifest = volume.appendingPathComponent("installer/INSTALLDATA.tgz.manifest")
        self.manifest = fileManager.fileExists(atPath: manifest.path) ? manifest : nil

        let apps = (try? fileManager.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)) ?? []
        let installPlist = apps
            .filter { $0.pathExtension == "app" }
            .map { $0.appendingPathComponent("Contents/Resources/tgInstall.plist") }
            .first { fileManager.fileExists(atPath: $0.path) }
        guard let installPlist else {
            throw NotCider(description: "it has no installer app with a tgInstall.plist")
        }
        let settings = NSDictionary(contentsOf: installPlist) as? [String: Any] ?? [:]
        gameName = settings["InstallGame"] as? String
        bundleIdentifier = settings["ForbiddenGameID"] as? String
    }

    /// The Cider app's paths for the files a wrapp takes from it.
    private static let infoPlistPattern = "*/Contents/Info.plist"
    private static let programFilesPattern = "*/Contents/Resources/transgaming/c_drive/Program Files/*"
    // Every --include must match something, or bsdtar fails ("Not found in
    // archive"), so one pattern for both cases.
    private static let system32Pattern = "*/Contents/Resources/transgaming/c_drive/windows/system32/*.[dD][lL][lL]"

    /// Extract the game into `driveC`, where the Windows installer would have
    /// put it, and return its exe.
    ///
    /// The payload goes through `tar` once, keeping the Cider app's
    /// `Info.plist` and the `Program Files` tree, into `staging` (which the
    /// caller owns and removes). `CedegaGameDir` and `CedegaGameName` in that
    /// `Info.plist` then say which folder is the game and which file its exe.
    /// Cider's `C:\Program Files` is a 32-bit Windows's, so the game moves to
    /// `Program Files (x86)`, where a 32-bit installer puts it in a wrapp.
    ///
    /// The game needs the runtimes a disc's installer installs alongside it —
    /// Trail of the Twister won't start without `MFC80.DLL` — and Cider
    /// supplied them from its `system32`. The DLLs there that have no
    /// builtin in `wineDLLs` (the wrapp's Wine's 32-bit DLL directory) are
    /// copied into the game's folder, where Windows looks first.
    ///
    /// `progress` gets the percentage of entries extracted, counted against
    /// the manifest, whenever it changes.
    func extractGame(
        into driveC: URL,
        staging: URL,
        wineDLLs: URL,
        progress: @escaping @Sendable (Int) async -> Void
    ) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try await untar(into: staging, progress: progress)

        guard let app = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw WrappBuildError.unsupportedMacDownload(reason: "its game archive has no app in it")
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        guard let gameDir = info["CedegaGameDir"] as? String,
              let gameExe = info["CedegaGameName"] as? String else {
            throw WrappBuildError.unsupportedMacDownload(reason: "its app doesn't name the game's folder and exe")
        }

        let ciderDriveC = app.appendingPathComponent("Contents/Resources/transgaming/c_drive")
        let source = ciderDriveC.appendingPathComponent(Self.relativePath(ofWindowsPath: gameDir))
        let destination = driveC.appendingPathComponent(Self.wrappRelativePath(ofWindowsPath: gameDir))
        guard fileManager.fileExists(atPath: source.path) else {
            throw WrappBuildError.unsupportedMacDownload(reason: "the game folder its app names (\(gameDir)) isn't in it")
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
        logger.notice("Moved the game from the Cider app's \(gameDir) to \(destination.path)")

        try Self.copyRuntimesWineLacks(
            from: ciderDriveC.appendingPathComponent("windows/system32"),
            wineDLLs: wineDLLs,
            into: destination
        )

        let exe = driveC.appendingPathComponent(Self.wrappRelativePath(ofWindowsPath: gameExe))
        guard fileManager.fileExists(atPath: exe.path) else {
            throw WrappBuildError.unsupportedMacDownload(reason: "the game's exe (\(gameExe)) isn't in its folder")
        }
        return exe
    }

    /// Copy the DLLs in Cider's `system32` that Wine has no builtin for into
    /// the game's folder, leaving any the game ships itself alone.
    nonisolated static func copyRuntimesWineLacks(from system32: URL, wineDLLs: URL, into gameDir: URL) throws {
        let fileManager = FileManager.default
        let builtins = Set(((try? fileManager.contentsOfDirectory(atPath: wineDLLs.path)) ?? []).map { $0.lowercased() })
        guard !builtins.isEmpty else {
            throw WrappBuildError.internalError("No Wine DLLs at \(wineDLLs.path) to compare Cider's with")
        }
        let gameFiles = Set(((try? fileManager.contentsOfDirectory(atPath: gameDir.path)) ?? []).map { $0.lowercased() })
        let ciderDLLs = ((try? fileManager.contentsOfDirectory(atPath: system32.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".dll") }
            .sorted()
        var copied: [String] = []
        for dll in ciderDLLs where !builtins.contains(dll.lowercased()) && !gameFiles.contains(dll.lowercased()) {
            try fileManager.copyItem(at: system32.appendingPathComponent(dll), to: gameDir.appendingPathComponent(dll))
            copied.append(dll)
        }
        logger.notice("Copied the runtimes Wine lacks from Cider's system32 into the game's folder: \(copied.isEmpty ? "none" : copied.joined(separator: ", "))")
    }

    /// `C:\Program Files\Nancy Drew\Game` → `Program Files/Nancy Drew/Game`.
    nonisolated static func relativePath(ofWindowsPath path: String) -> String {
        var path = path.replacingOccurrences(of: "\\", with: "/")
        if path.count >= 2, path.dropFirst().first == ":" {
            path = String(path.dropFirst(2))
        }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Where a Cider path goes in a wrapp's `drive_c`: as `relativePath`,
    /// but with `Program Files` as `Program Files (x86)`.
    nonisolated static func wrappRelativePath(ofWindowsPath path: String) -> String {
        let relative = relativePath(ofWindowsPath: path)
        let programFiles = "Program Files/"
        guard relative.lowercased().hasPrefix(programFiles.lowercased()) else { return relative }
        return "Program Files (x86)/" + relative.dropFirst(programFiles.count)
    }

    /// The manifest's count of the entries `extractGame` keeps, for progress.
    nonisolated static func entryCount(inManifest manifest: String) -> Int {
        let programFiles = "/Contents/Resources/transgaming/c_drive/Program Files/"
        let system32 = "/Contents/Resources/transgaming/c_drive/windows/system32/"
        return manifest.split(whereSeparator: \.isNewline).filter { line in
            if line.hasSuffix("/Contents/Info.plist") { return line.split(separator: "/").count == 3 }
            if let range = line.range(of: system32) {
                return !line[range.upperBound...].contains("/") && line.lowercased().hasSuffix(".dll")
            }
            guard let range = line.range(of: programFiles) else { return false }
            return range.upperBound < line.endIndex
        }.count
    }

    private func untar(into staging: URL, progress: @escaping @Sendable (Int) async -> Void) async throws {
        let total = manifest
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map(Self.entryCount(inManifest:)) ?? 0
        logger.notice("Extracting \(payload.lastPathComponent) (\(total) entries to keep)")

        let extracted = Counter()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "-xzvf", payload.path, "-C", staging.path,
            "--include", Self.infoPlistPattern,
            "--include", Self.programFilesPattern,
            "--include", Self.system32Pattern,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // bsdtar names each entry it extracts as "x <path>" on stderr: a
        // count for progress, and too many lines to show on the terminal.
        ProcessLineLogger.attach(to: stdout, logger: tarLogger, level: .notice)
        ProcessLineLogger.attach(
            to: stderr, logger: tarLogger, level: .warning,
            levelFor: { $0.hasPrefix("x ") ? .debug : .warning },
            onLine: { if $0.hasPrefix("x ") { extracted.increment() } }
        )

        let exit = AsyncStream<Int32> { continuation in
            process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        }
        try process.run()

        let reporter = Task {
            var lastPercent = -1
            while !Task.isCancelled {
                if total > 0 {
                    let percent = min(100, extracted.value * 100 / total)
                    if percent != lastPercent {
                        lastPercent = percent
                        await progress(percent)
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { reporter.cancel() }

        var status: Int32 = -1
        for await code in exit { status = code }
        guard status == 0 else {
            logger.error("tar exited \(status) extracting \(payload.path)")
            throw WrappBuildError.unsupportedMacDownload(
                reason: "its game archive couldn't be extracted (tar exited \(status)); the download may be incomplete")
        }
        logger.notice("Extracted \(extracted.value) entries")
    }
}

/// A count bumped from a pipe's reader queue and read from a task.
private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
