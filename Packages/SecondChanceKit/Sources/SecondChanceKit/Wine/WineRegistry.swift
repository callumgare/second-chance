//
//  WineRegistry.swift
//  Shared
//
//  Reading and writing a prefix's registry through Wine's `reg`.

import Foundation

nonisolated extension Wine {
    public var registry: WineRegistry { WineRegistry(wine: self) }
}

nonisolated public struct WineRegistry: Sendable {
    /// A registry key, as `reg` takes it.
    public struct Key: RawRepresentable, ExpressibleByStringLiteral, Sendable, Equatable {
        public let rawValue: String

        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }

        /// Wine's display settings, `EmulateModeset` among them. Wine 10
        /// reads them from here whatever the driver.
        public static let x11Driver: Key = #"HKEY_CURRENT_USER\Software\Wine\X11 Driver"#
        /// What kind of drive each drive letter is.
        public static let wineDrives: Key = #"HKEY_LOCAL_MACHINE\Software\Wine\Drives"#
        /// Volatile: filled in by the desktop once it has registered the
        /// display devices (`WineDesktop`).
        public static let videoDeviceMap: Key = #"HKLM\HARDWARE\DEVICEMAP\VIDEO"#
    }

    public enum Value: Sendable, Equatable {
        case string(String)
        case dword(UInt32)
    }

    let wine: Wine

    /// Set `name` in `key` to `value`, creating the key if need be.
    ///
    /// A write takes seconds on an idle machine but over a minute with every
    /// core busy, starting the Wine session being most of it; one that runs
    /// for the default ten means the prefix is broken.
    public func set(_ value: Value, for name: String, in key: Key, timeout: TimeInterval = 600) async throws {
        let (type, data) = switch value {
        case .string(let string): ("REG_SZ", string)
        case .dword(let number): ("REG_DWORD", String(number))
        }
        try await wine.run(.wine(["reg", "add", key.rawValue, "/v", name, "/t", type, "/d", data, "/f"]), timeout: timeout)
    }

    /// Have ⌘ act as Ctrl in the windows of the programs named `exes`
    /// (`steam.exe`), and in no others. Wine keeps ⌘ shortcuts for its own
    /// Mac menu, so ⌘C and ⌘V never reach a Windows program, which knows only
    /// Ctrl's: Steam's and Big Fish's sign-in forms want them. Not for a game,
    /// whose ⌘Q has to stay a quit (Wine's `AppDefaults\<exe>\Mac Driver`).
    public func letCommandActAsControl(in exes: [String]) async throws {
        for exe in exes {
            let key = Key(rawValue: #"HKEY_CURRENT_USER\Software\Wine\AppDefaults\"# + exe + #"\Mac Driver"#)
            for name in ["LeftCommandIsCtrl", "RightCommandIsCtrl"] {
                try await set(.string("y"), for: name, in: key)
            }
        }
    }

    /// Delete `name` from `key`. Deleting what isn't there isn't an error.
    public func deleteValue(_ name: String, in key: Key, timeout: TimeInterval = 600) async throws {
        do {
            try await wine.run(.wine(["reg", "delete", key.rawValue, "/v", name, "/f"]), timeout: timeout)
        } catch WineError.executionFailed {
            // reg exits 1 when the key or value doesn't exist.
        }
    }

    /// Import the `.reg` file at `path`, a path as Windows programs see it.
    public func importFile(atWindowsPath path: String, timeout: TimeInterval) async throws {
        try await wine.run(.wine(["reg", "import", path]), timeout: timeout)
    }

    /// `reg query`'s listing of `key`. A timeout stops only `reg`, not the
    /// session, so a check can't end what it's checking on.
    public func values(in key: Key, timeout: TimeInterval) async throws -> String {
        try await wine.output(of: .wine(["reg", "query", key.rawValue]), timeout: timeout, onTimeout: .stopProgram)
    }
}
