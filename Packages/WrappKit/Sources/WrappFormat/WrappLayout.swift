//
//  WrappLayout.swift
//  WrappFormat
//
//  Where things are inside a wrapp.

import Foundation

/// Where things are inside a wrapp, the `.app` Second Chance makes for a
/// game. The build writes them and the wrapp and WrappPuppeteer read them,
/// so all three find them here.
///
/// The prefix here is the wrapp's own. A wrapp run from somewhere it can't
/// write runs in a copy of it instead, so what the game sees inside a prefix
/// is asked of the `Wine` running it (`driveC`, `documents`, `drives`).
nonisolated public struct WrappLayout: Sendable, Hashable {
    /// The wrapp itself.
    public let app: URL

    public init(app: URL) {
        self.app = app
    }

    public var infoPlist: URL { app.appendingPathComponent("Contents/Info.plist") }
    public var resources: URL { app.appendingPathComponent("Contents/Resources") }
    /// What the build says about the game (`WrappSettings`).
    public var settingsFile: URL { resources.appendingPathComponent("AppSettings.plist") }
    /// What the wrapp was built from (`WrappLock`).
    public var lockFile: URL { resources.appendingPathComponent("WrappLock.json") }
    public var frameworks: URL { app.appendingPathComponent("Contents/Frameworks") }
    /// ScummVM, for a game it runs.
    public var scummvm: URL { app.appendingPathComponent("Contents/MacOS/scummvm") }
    /// DOSBox Staging, for a game it runs.
    public var dosbox: URL { app.appendingPathComponent("Contents/MacOS/dosbox") }
    /// The bundled Wine, for a game it runs.
    public var wine: URL { app.appendingPathComponent("Contents/SharedSupport/wine") }
    /// The Wine prefix the game is installed in.
    public var prefix: URL { app.appendingPathComponent("Contents/SharedSupport/prefix") }
    /// The prefix's C: drive.
    public var driveC: URL { prefix.appendingPathComponent("drive_c") }
    /// Where a build puts the game's installer: one `disk-N` folder per disc,
    /// and `disk-combined` for a game on more than one. Kept in the finished
    /// wrapp, mounted as CD drives, for games that check for their disc
    /// before they will play.
    public var installers: URL { driveC.appendingPathComponent(Self.installersFolder) }
    /// The folder in drive_c a build copies the discs or installer into.
    public static let installersFolder = "nancy-drew-installer"

    /// The file at `windowsPath` on the C: drive, a path from its root with
    /// forward slashes as `WrappSettings.gameExePath` has it
    /// (`/Program Files (x86)/Nancy Drew/Game.exe`).
    public func onDriveC(_ windowsPath: String) -> URL {
        Self.onDriveC(windowsPath, in: driveC)
    }

    /// `onDriveC(_:)` for the C: drive at `driveC`, which may be another
    /// prefix's.
    public static func onDriveC(_ windowsPath: String, in driveC: URL) -> URL {
        driveC.appendingPathComponent(String(windowsPath.drop { $0 == "/" }))
    }

    /// DOSBox's C:, the drive the game sees: a folder of its own, as Wine's
    /// C: is the prefix's `drive_c`.
    public var dosboxC: URL { app.appendingPathComponent("Contents/SharedSupport/dosbox/c") }

    /// Where a location in full form is in the app (docs/wrappfile.md#path-types):
    /// `wine:C:/…` on the prefix's C: drive, `dosbox:C:/…` on DOSBox's, and a
    /// bare `/…` in the app's `Contents/`, `/../` its top level. Nil for one
    /// whose type has no place in the app, or a bare path that goes above it.
    public func location(_ fullForm: String) -> URL? {
        func onDrive(_ path: Substring, _ drive: URL) -> URL? {
            guard path.hasPrefix("C:/") || path == "C:" else { return nil }
            return drive.appendingPathComponent(String(path.dropFirst(2).drop { $0 == "/" }))
        }
        if fullForm.hasPrefix("wine:") { return onDrive(fullForm.dropFirst("wine:".count), driveC) }
        if fullForm.hasPrefix("dosbox:") { return onDrive(fullForm.dropFirst("dosbox:".count), dosboxC) }
        guard fullForm.hasPrefix("/") else { return nil }
        // `/` is Contents/, one below the top: no `..` may climb past the top.
        var depth = 1
        for part in fullForm.split(separator: "/") {
            depth += part == ".." ? -1 : part == "." ? 0 : 1
            if depth < 0 { return nil }
        }
        return app.appendingPathComponent("Contents").appendingPathComponent(String(fullForm.dropFirst())).standardizedFileURL
    }
}
