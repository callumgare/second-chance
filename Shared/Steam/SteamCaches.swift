//
//  SteamCaches.swift
//  Shared
//
//  What a signed-in Steam keeps on disk about the account's games: which apps
//  it owns (appcache/packageinfo.vdf), what they are (appcache/appinfo.vdf),
//  and how far an install has got (steamapps/appmanifest_<id>.acf).

import Foundation

/// One app from appinfo.vdf, as much of it as a wrapp build needs.
nonisolated struct SteamAppInfo: Equatable, Sendable {
    struct Launch: Equatable, Sendable {
        let executable: String
        let arguments: String?
        /// `windows`, `macos`, … or nil when the entry is for every OS.
        let osList: String?
    }

    let appID: Int
    let name: String
    let type: String
    /// The folder under `steamapps/common/` it installs into.
    let installDir: String?
    let launches: [Launch]

    /// The Windows executable, relative to the install dir.
    var windowsExecutable: String? {
        launches.first { $0.osList == nil || $0.osList?.contains("windows") == true }?.executable
    }
}

nonisolated enum SteamCaches {
    /// The app IDs the account holds a licence for: every app in every
    /// package in packageinfo.vdf, which Steam fills in for the signed-in
    /// account's licences.
    ///
    /// Steam never reports an install of an app the account doesn't own —
    /// its manifest just sits there — so ownership has to be checked here
    /// first. See docs/steam.md.
    static func ownedAppIDs(packageInfo data: Data) throws -> Set<Int> {
        var reader = BinaryReader(data: data)
        let magic = try reader.uint32()
        _ = try reader.uint32()  // universe
        guard magic >> 8 == 0x065655 else {
            throw VDFError.badBinary("not a packageinfo.vdf (magic \(String(magic, radix: 16)))", offset: 0)
        }
        let hasToken = (magic & 0xFF) >= 0x28
        var owned = Set<Int>()
        while true {
            let packageID = try reader.uint32()
            if packageID == 0xFFFF_FFFF { return owned }
            try reader.skip(20 + 4)  // SHA-1, change number
            if hasToken { try reader.skip(8) }
            var offset = reader.offset
            let entries = try VDF.parseBinary(data, at: &offset)
            reader.offset = offset
            let package = entries.first?.value
            for entry in package?["appids"]?.entries ?? [] {
                if let id = entry.value.int { owned.insert(Int(id)) }
            }
        }
    }

    /// Every app in appinfo.vdf (formats 27–29) by ID. An entry that doesn't
    /// parse is skipped rather than failing the lot.
    static func apps(appInfo data: Data) throws -> [Int: SteamAppInfo] {
        var reader = BinaryReader(data: data)
        let magic = try reader.uint32()
        _ = try reader.uint32()  // universe
        guard magic >> 8 == 0x075644 else {
            throw VDFError.badBinary("not an appinfo.vdf (magic \(String(magic, radix: 16)))", offset: 0)
        }
        let version = magic & 0xFF
        var strings: [String]?
        if version >= 0x29 {
            // v29 moved keys into a string table at the end of the file.
            var table = BinaryReader(data: data, offset: Int(Int64(bitPattern: try reader.uint64())))
            let count = Int(try table.uint32())
            strings = try (0..<count).map { _ in try table.cString() }
        }
        var apps: [Int: SteamAppInfo] = [:]
        while true {
            let appID = Int(try reader.uint32())
            if appID == 0 { return apps }
            let size = Int(try reader.uint32())
            let end = reader.offset + size
            // info state, last updated, token, SHA-1, change number, then
            // (from v28) the binary data's SHA-1.
            var offset = reader.offset + 4 + 4 + 8 + 20 + 4 + (version >= 0x28 ? 20 : 0)
            if let entries = try? VDF.parseBinary(data, at: &offset, strings: strings),
               let info = appInfo(appID: appID, entries: entries) {
                apps[appID] = info
            }
            reader.offset = end
        }
    }

    private static func appInfo(appID: Int, entries: [VDFEntry]) -> SteamAppInfo? {
        let root = VDFValue.object(entries)
        let app = root["appinfo"] ?? root
        guard let common = app["common"] else { return nil }
        let launches = (app["config"]?["launch"]?.entries ?? []).compactMap { entry -> SteamAppInfo.Launch? in
            guard let executable = entry.value["executable"]?.string else { return nil }
            return SteamAppInfo.Launch(
                executable: executable,
                arguments: entry.value["arguments"]?.string,
                osList: entry.value["config"]?["oslist"]?.string
            )
        }
        return SteamAppInfo(
            appID: appID,
            name: common["name"]?.string?.trimmingCharacters(in: .whitespaces) ?? "",
            type: common["type"]?.string ?? "",
            installDir: app["config"]?["installdir"]?.string,
            launches: launches
        )
    }
}

/// `steamapps/appmanifest_<id>.acf`: Steam's record of one app's install.
nonisolated struct SteamAppManifest: Equatable, Sendable {
    /// `StateFlags` bits Steam sets.
    static let fullyInstalled: Int64 = 4
    static let updateRequired: Int64 = 2
    static let updateStarted: Int64 = 1024

    let appID: Int
    let installDir: String?
    let stateFlags: Int64
    let bytesToDownload: Int64?
    let bytesDownloaded: Int64?

    var isFullyInstalled: Bool { stateFlags & Self.fullyInstalled != 0 }

    init?(text: String) {
        guard let state = try? VDF.parse(text)["AppState"],
              let appID = state["appid"]?.int else { return nil }
        self.appID = Int(appID)
        installDir = state["installdir"]?.string
        stateFlags = state["StateFlags"]?.int ?? 0
        bytesToDownload = state["BytesToDownload"]?.int
        bytesDownloaded = state["BytesDownloaded"]?.int
    }

    /// The smallest manifest that makes Steam install the app the next time
    /// it starts, with no dialog: written while Steam isn't running, Steam
    /// takes it as an install that needs an update. These four keys are all
    /// it needs; see docs/steam.md.
    static func installStub(appID: Int, installDir: String) -> String {
        let state: [VDFEntry] = [
            VDFEntry(key: "appid", value: .string(String(appID))),
            VDFEntry(key: "Universe", value: .string("1")),
            VDFEntry(key: "installdir", value: .string(installDir)),
            VDFEntry(key: "StateFlags", value: .string(String(updateRequired | updateStarted))),
        ]
        return VDF.format([VDFEntry(key: "AppState", value: .object(state))])
    }
}
