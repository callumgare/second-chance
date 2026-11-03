//
//  MachOPatch.swift
//  WrappBuilder
//
//  Adding a weak dependency to a Mach-O file, in the padding after its
//  load commands: how Wine's Mac driver is made to load the in-process
//  helpers (docs/wine-in-process-helpers.md).

import Foundation

/// Adds a dependency to a thin 64-bit Mach-O file without Xcode's tools.
///
/// Wine child processes are launched through wine-preloader, which loads
/// the real wine binary in a second dyld pass. DYLD_INSERT_LIBRARIES only
/// applies to the first pass, and the preloader reaches its entry point
/// before dyld's initializer phase runs, so an injected dylib is mapped
/// into the game process but its constructor never fires. Making the dylib
/// a genuine dependency of winemac.so puts it in the second pass's image
/// graph, where dyld does run initializers.
///
/// The dependency is weak (LC_LOAD_WEAK_DYLIB), so a missing or unreadable
/// dylib degrades to "no in-process helpers" — no native fullscreen or
/// cursor lock — instead of breaking Wine's graphics driver. The file must
/// be signed again afterwards: its signature no longer matches.
public nonisolated enum MachOPatch {
    static let magic64: UInt32 = 0xfeed_facf
    static let segment64: UInt32 = 0x19
    static let loadDylib: UInt32 = 0x0c
    static let idDylib: UInt32 = 0x0d
    static let loadWeakDylib: UInt32 = 0x8000_0018
    static let reexportDylib: UInt32 = 0x8000_001f
    static let loadUpwardDylib: UInt32 = 0x8000_0023
    static let rpath: UInt32 = 0x8000_001c

    /// Add a weak dependency on `reference` to the file at `url`. False when
    /// it already has one, leaving it as it was.
    @discardableResult
    public static func addWeakDylib(_ url: URL, reference: String) throws -> Bool {
        try add(to: url, command: dylibCommand(reference: reference)) { data, commands in
            try referencedDylibs(data, commands: commands).contains(reference)
        }
    }

    /// Add `path` to the file's run-path search list (LC_RPATH), as
    /// `install_name_tool -add_rpath` does: where its `@rpath/` dependencies
    /// are looked for. False when it already has it.
    @discardableResult
    public static func addRunPath(_ url: URL, path: String) throws -> Bool {
        try add(to: url, command: stringCommand(rpath, path)) { data, commands in
            try runPaths(data, commands: commands).contains(path)
        }
    }

    /// The file's run paths.
    public static func runPaths(of url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        return try runPaths(data, commands: loadCommands(data, count: readUInt32(data, 16)))
    }

    /// Write `command` into the padding after the file's load commands,
    /// unless `present` says it is there already.
    static func add(to url: URL, command: Data, present: (Data, [LoadCommand]) throws -> Bool) throws -> Bool {
        var data = try Data(contentsOf: url)
        guard data.count >= 32, try readUInt32(data, 0) == magic64 else {
            throw EngineError("\(url.lastPathComponent) isn't a thin 64-bit Mach-O file")
        }
        let commandCount = try readUInt32(data, 16)
        let commandsSize = try readUInt32(data, 20)
        let commands = try loadCommands(data, count: commandCount)
        if try present(data, commands) { return false }

        let headerEnd = 32 + Int(commandsSize)
        let available = try firstContentOffset(data, commands: commands) - headerEnd
        guard command.count <= available else {
            throw EngineError("\(url.lastPathComponent) has no room for another load command: \(command.count) bytes needed, \(available) free")
        }
        let padding = headerEnd..<(headerEnd + command.count)
        guard data[padding].allSatisfy({ $0 == 0 }) else {
            throw EngineError("\(url.lastPathComponent)'s header padding isn't empty")
        }
        data.replaceSubrange(padding, with: command)
        writeUInt32(&data, 16, commandCount + 1)
        writeUInt32(&data, 20, commandsSize + UInt32(command.count))
        try data.write(to: url)
        return true
    }

    /// The names the file's dylib commands refer to.
    public static func dependencies(of url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        return try referencedDylibs(data, commands: loadCommands(data, count: readUInt32(data, 16)))
    }

    // MARK: - Reading and writing

    struct LoadCommand {
        let kind: UInt32
        let offset: Int
        let size: Int
    }

    static func readUInt32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw EngineError("read past the end of a Mach-O file") }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + offset + $1]) << (8 * UInt32($1)) }
    }

    static func readUInt64(_ data: Data, _ offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { throw EngineError("read past the end of a Mach-O file") }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[data.startIndex + offset + $1]) << (8 * UInt64($1)) }
    }

    static func writeUInt32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        for byte in 0..<4 {
            data[data.startIndex + offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(byte)))
        }
    }

    static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        for byte in 0..<4 {
            data.append(UInt8(truncatingIfNeeded: value >> (8 * UInt32(byte))))
        }
    }

    static func loadCommands(_ data: Data, count: UInt32) throws -> [LoadCommand] {
        var commands: [LoadCommand] = []
        var offset = 32
        for _ in 0..<Int(count) {
            let kind = try readUInt32(data, offset)
            let size = Int(try readUInt32(data, offset + 4))
            guard size >= 8 else { throw EngineError("a malformed load command at offset \(offset)") }
            commands.append(LoadCommand(kind: kind, offset: offset, size: size))
            offset += size
        }
        return commands
    }

    static func referencedDylibs(_ data: Data, commands: [LoadCommand]) throws -> [String] {
        let kinds: Set<UInt32> = [loadDylib, idDylib, loadWeakDylib, reexportDylib, loadUpwardDylib]
        return try commands.filter { kinds.contains($0.kind) }.compactMap { try string(in: $0, of: data) }
    }

    static func runPaths(_ data: Data, commands: [LoadCommand]) throws -> [String] {
        try commands.filter { $0.kind == rpath }.compactMap { try string(in: $0, of: data) }
    }

    /// The string a dylib or rpath command holds, at the offset its third
    /// field gives.
    static func string(in command: LoadCommand, of data: Data) throws -> String? {
        let nameOffset = Int(try readUInt32(data, command.offset + 8))
        guard nameOffset < command.size else { return nil }
        let start = data.startIndex + command.offset + nameOffset
        let end = data.startIndex + command.offset + command.size
        return String(decoding: data[start..<end].prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The lowest file offset of any section with contents: how far the
    /// load commands can grow.
    static func firstContentOffset(_ data: Data, commands: [LoadCommand]) throws -> Int {
        var lowest: Int?
        for command in commands where command.kind == segment64 {
            let sectionCount = Int(try readUInt32(data, command.offset + 64))
            var section = command.offset + 72
            for _ in 0..<sectionCount {
                let size = try readUInt64(data, section + 40)
                let fileOffset = Int(try readUInt32(data, section + 48))
                if fileOffset > 0 && size > 0 { lowest = min(lowest ?? fileOffset, fileOffset) }
                section += 80
            }
        }
        guard let lowest else { throw EngineError("a Mach-O file with no sections") }
        return lowest
    }

    /// A weak dylib_command: cmd, cmdsize, name offset, timestamp, current
    /// and compatibility versions, then the name, padded to 8 bytes.
    static func dylibCommand(reference: String) -> Data {
        var fields = Data()
        appendUInt32(&fields, 0)
        appendUInt32(&fields, 0x1_0000)
        appendUInt32(&fields, 0x1_0000)
        return command(loadWeakDylib, fields: fields, string: reference)
    }

    /// An rpath_command: cmd, cmdsize, path offset, then the path.
    static func stringCommand(_ kind: UInt32, _ string: String) -> Data {
        command(kind, fields: Data(), string: string)
    }

    /// cmd, cmdsize, the string's offset, `fields`, then the string, padded
    /// to 8 bytes.
    static func command(_ kind: UInt32, fields: Data, string: String) -> Data {
        let name = Array(string.utf8) + [0]
        let header = 12 + fields.count
        let unpadded = header + name.count
        let size = (unpadded + 7) & ~7
        var command = Data()
        appendUInt32(&command, kind)
        appendUInt32(&command, UInt32(size))
        appendUInt32(&command, UInt32(header))
        command.append(fields)
        command.append(contentsOf: name)
        command.append(contentsOf: [UInt8](repeating: 0, count: size - unpadded))
        return command
    }
}
