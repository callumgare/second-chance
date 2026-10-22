//
//  SteamVDFTests.swift
//  SecondChanceTests
//
//  Valve's KeyValues, text and binary, and the Steam caches read with it.

import Foundation
import Testing
@testable import SecondChance

/// Builds binary KeyValues and the cache files around them.
struct BinaryVDFBuilder {
    var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func cString(_ value: String) { data.append(contentsOf: Array(value.utf8) + [0]) }
    mutating func zeros(_ count: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: count)) }

    /// Keys inline, or as indices into `table` (which collects them).
    mutating func key(_ key: String, table: inout [String]?) {
        if var strings = table {
            if let index = strings.firstIndex(of: key) {
                u32(UInt32(index))
            } else {
                strings.append(key)
                u32(UInt32(strings.count - 1))
            }
            table = strings
        } else {
            cString(key)
        }
    }

    mutating func kv(_ entries: [(String, Any)], table: inout [String]?) {
        for (name, value) in entries {
            switch value {
            case let string as String:
                u8(0x01); key(name, table: &table); cString(string)
            case let int as Int:
                u8(0x02); key(name, table: &table); u32(UInt32(bitPattern: Int32(int)))
            case let children as [(String, Any)]:
                u8(0x00); key(name, table: &table); kv(children, table: &table)
            default:
                Issue.record("unsupported value \(value)")
            }
        }
        u8(0x08)
    }
}

@Suite("Steam KeyValues")
struct SteamVDFTests {
    @Test("Text: nested objects, escapes, comments and platform conditions")
    func parsesText() throws {
        let text = #"""
        // a comment
        "AppState"
        {
            "appid"   "615770"
            "name"    "Say \"hi\"\\there"
            Bare      value
            "UserConfig"
            {
                "language"  "english"   [$WIN32]
            }
        }
        """#
        let root = try VDF.parse(text)
        let state = try #require(root["appstate"])  // keys are case-insensitive
        #expect(state["appid"]?.int == 615770)
        #expect(state["name"]?.string == #"Say "hi"\there"#)
        #expect(state["bare"]?.string == "value")
        #expect(state["UserConfig"]?["language"]?.string == "english")
        #expect(state.entries.map(\.key) == ["appid", "name", "Bare", "UserConfig"])
    }

    @Test("Text: unbalanced braces are an error", arguments: [#""a" {"#, #""a" "b" }"#, #""a""#])
    func rejectsBrokenText(text: String) {
        #expect(throws: VDFError.self) { try VDF.parse(text) }
    }

    @Test("Formatting round-trips")
    func formatsText() throws {
        let entries = [VDFEntry(key: "A", value: .object([
            VDFEntry(key: "path", value: .string(#"C:\Program Files "x86""#)),
            VDFEntry(key: "n", value: .string("1")),
        ]))]
        #expect(try VDF.parse(VDF.format(entries)) == .object(entries))
    }

    @Test("Binary: inline keys and a string table read the same")
    func parsesBinary() throws {
        let entries: [(String, Any)] = [("common", [("name", "Game"), ("type", "Game")] as [(String, Any)]), ("id", 7)]
        for useTable in [false, true] {
            var builder = BinaryVDFBuilder()
            var table: [String]? = useTable ? [] : nil
            builder.kv(entries, table: &table)
            var offset = 0
            let parsed = VDFValue.object(try VDF.parseBinary(builder.data, at: &offset, strings: table))
            #expect(parsed["common"]?["name"]?.string == "Game")
            #expect(parsed["id"]?.int == 7)
            #expect(offset == builder.data.count)
        }
    }

    @Test("Binary: truncated data is an error, not a crash")
    func rejectsTruncatedBinary() {
        var builder = BinaryVDFBuilder()
        var table: [String]?
        builder.kv([("name", "Game")], table: &table)
        let truncated = builder.data.prefix(builder.data.count - 3)
        var offset = 0
        #expect(throws: VDFError.self) { try VDF.parseBinary(Data(truncated), at: &offset) }
    }
}

@Suite("Steam caches and manifests")
struct SteamCachesTests {
    /// A packageinfo.vdf (v28) with these packages' app IDs.
    func packageInfo(_ packages: [[Int]]) -> Data {
        var b = BinaryVDFBuilder()
        b.u32(0x0656_5528); b.u32(1)
        var table: [String]?
        for (index, apps) in packages.enumerated() {
            b.u32(UInt32(index + 100)); b.zeros(20); b.u32(1); b.u64(0)
            let ids: [(String, Any)] = apps.enumerated().map { (String($0.offset), $0.element) }
            b.kv([(String(index + 100), [("packageid", index + 100), ("appids", ids)] as [(String, Any)])], table: &table)
        }
        b.u32(0xFFFF_FFFF)
        return b.data
    }

    /// An appinfo.vdf, v29 (string table) or v28 (inline keys).
    func appInfo(version: UInt32, apps: [(Int, [(String, Any)])]) -> Data {
        var b = BinaryVDFBuilder()
        b.u32(0x0756_4400 | version); b.u32(1)
        var table: [String]? = version >= 0x29 ? [] : nil
        let tableOffsetAt = b.data.count
        if version >= 0x29 { b.u64(0) }  // patched below
        for (id, kv) in apps {
            var body = BinaryVDFBuilder()
            body.u32(0); body.u32(0); body.u64(0); body.zeros(20); body.u32(1)
            if version >= 0x28 { body.zeros(20) }
            body.kv([("appinfo", kv)], table: &table)
            b.u32(UInt32(id)); b.u32(UInt32(body.data.count)); b.data.append(body.data)
        }
        b.u32(0)
        if let strings = table {
            let offset = UInt64(b.data.count)
            withUnsafeBytes(of: offset.littleEndian) { b.data.replaceSubrange(tableOffsetAt..<tableOffsetAt + 8, with: $0) }
            b.u32(UInt32(strings.count))
            strings.forEach { b.cString($0) }
        }
        return b.data
    }

    @Test("Owned apps are every app in every licensed package")
    func ownedApps() throws {
        #expect(try SteamCaches.ownedAppIDs(packageInfo: packageInfo([[615770, 615771], [226820]])) == [615770, 615771, 226820])
        #expect(throws: VDFError.self) { try SteamCaches.ownedAppIDs(packageInfo: Data([1, 2, 3, 4, 5, 6, 7, 8])) }
    }

    @Test("App info gives the name, install dir and Windows executable", arguments: [UInt32(0x28), 0x29])
    func appDetails(version: UInt32) throws {
        let haunted: [(String, Any)] = [
            ("common", [("name", "Nancy Drew: Message in a Haunted Mansion "), ("type", "Game")] as [(String, Any)]),
            ("config", [
                ("installdir", "Nancy Drew Message in a Haunted Mansion"),
                ("launch", [
                    ("0", [("executable", "Game.app"), ("config", [("oslist", "macos")] as [(String, Any)])] as [(String, Any)]),
                    ("1", [("executable", "Game.exe"), ("config", [("oslist", "windows")] as [(String, Any)])] as [(String, Any)]),
                ] as [(String, Any)]),
            ] as [(String, Any)]),
        ]
        let apps = try SteamCaches.apps(appInfo: appInfo(version: version, apps: [(615770, haunted), (7, [("common", [("name", "Tool"), ("type", "Tool")] as [(String, Any)])])]))
        let app = try #require(apps[615770])
        #expect(app.name == "Nancy Drew: Message in a Haunted Mansion")
        #expect(app.type == "Game")
        #expect(app.installDir == "Nancy Drew Message in a Haunted Mansion")
        #expect(app.windowsExecutable == "Game.exe")
        #expect(apps[7]?.name == "Tool")
    }

    @Test("A manifest's state, and the stub that starts an install")
    func manifests() throws {
        let stub = SteamAppManifest.installStub(appID: 615770, installDir: "Nancy Drew Message in a Haunted Mansion")
        let queued = try #require(SteamAppManifest(text: stub))
        #expect(queued.appID == 615770)
        #expect(queued.installDir == "Nancy Drew Message in a Haunted Mansion")
        #expect(queued.stateFlags == 1026)
        #expect(!queued.isFullyInstalled)

        let done = try #require(SteamAppManifest(text: """
        "AppState"
        {
        \t"appid"\t\t"615770"
        \t"StateFlags"\t\t"4"
        \t"BytesToDownload"\t\t"396785744"
        \t"BytesDownloaded"\t\t"396785744"
        }
        """))
        #expect(done.isFullyInstalled)
        #expect(done.bytesDownloaded == 396_785_744)
        #expect(SteamAppManifest(text: "not a manifest") == nil)
    }
}
