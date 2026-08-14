#!/usr/bin/env swift

//  patch-winemac.swift
//  Adds a weak dependency on native_fullscreen.dylib to Wine's Mac driver.
//
//  Wine child processes are launched through wine-preloader, which loads the real
//  wine binary in a second dyld pass. DYLD_INSERT_LIBRARIES only applies to the
//  first pass, and the preloader reaches its entry point before dyld's initializer
//  phase runs -- so an injected dylib is mapped into the game process but its
//  constructor never fires. Making the dylib a genuine dependency of winemac.so
//  puts it in the second pass's image graph, where dyld does run initializers.
//
//  The dependency is weak (LC_LOAD_WEAK_DYLIB) so a missing or unreadable dylib
//  degrades to "no native fullscreen" instead of breaking Wine's graphics driver.
//
//  Usage: patch-winemac.swift <path-to-winemac.so>

import Foundation

let MH_MAGIC_64: UInt32 = 0xfeed_facf
let LC_SEGMENT_64: UInt32 = 0x19
let LC_LOAD_DYLIB: UInt32 = 0x0c
let LC_ID_DYLIB: UInt32 = 0x0d
let LC_LOAD_WEAK_DYLIB: UInt32 = 0x8000_0018
let LC_REEXPORT_DYLIB: UInt32 = 0x8000_001f

// winemac.so lives at Contents/SharedSupport/wine/lib/wine/x86_64-unix/, so five
// levels up from its directory is Contents/. Keeping the reference relative to
// @loader_path means the patch survives the .app being renamed or moved.
let dylibReference = "@loader_path/../../../../../Frameworks/native_fullscreen.dylib"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else { fail("read past end of file") }
    return UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}

func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
    guard offset >= 0, offset + 8 <= data.count else { fail("read past end of file") }
    return (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << (8 * UInt64($1)) }
}

func writeUInt32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
    for byte in 0..<4 {
        data[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(byte)))
    }
}

func appendUInt32(_ data: inout Data, _ value: UInt32) {
    for byte in 0..<4 {
        data.append(UInt8(truncatingIfNeeded: value >> (8 * UInt32(byte))))
    }
}

struct LoadCommand {
    let kind: UInt32
    let offset: Int
    let size: Int
}

func loadCommands(_ data: Data, count: UInt32) -> [LoadCommand] {
    var commands: [LoadCommand] = []
    var offset = 32
    for _ in 0..<Int(count) {
        let kind = readUInt32(data, offset)
        let size = Int(readUInt32(data, offset + 4))
        guard size >= 8 else { fail("malformed load command at offset \(offset)") }
        commands.append(LoadCommand(kind: kind, offset: offset, size: size))
        offset += size
    }
    return commands
}

/// Names referenced by the dylib-flavoured load commands, used to stay idempotent.
func referencedDylibs(_ data: Data, commands: [LoadCommand]) -> [String] {
    let dylibKinds: Set<UInt32> = [LC_LOAD_DYLIB, LC_ID_DYLIB, LC_LOAD_WEAK_DYLIB,
                                   LC_REEXPORT_DYLIB, 0x18]
    return commands.compactMap { command in
        guard dylibKinds.contains(command.kind) else { return nil }
        let nameOffset = Int(readUInt32(data, command.offset + 8))
        guard nameOffset < command.size else { return nil }

        var bytes: [UInt8] = []
        for index in (command.offset + nameOffset)..<(command.offset + command.size) {
            let byte = data[index]
            if byte == 0 { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Lowest non-zero section file offset: the ceiling for growing the header.
func firstContentOffset(_ data: Data, commands: [LoadCommand]) -> Int {
    var lowest: Int?
    for command in commands where command.kind == LC_SEGMENT_64 {
        let sectionCount = Int(readUInt32(data, command.offset + 64))
        var section = command.offset + 72
        for _ in 0..<sectionCount {
            let size = readUInt64(data, section + 40)
            let fileOffset = Int(readUInt32(data, section + 48))
            if fileOffset > 0 && size > 0 {
                lowest = min(lowest ?? fileOffset, fileOffset)
            }
            section += 80
        }
    }
    guard let result = lowest else { fail("no sections with file content found") }
    return result
}

func buildLoadCommand(reference: String) -> Data {
    var name = Array(reference.utf8)
    name.append(0)

    // dylib_command is 24 bytes: cmd, cmdsize, name_offset, timestamp,
    // current_version, compatibility_version. cmdsize must be 8-byte aligned.
    let unpadded = 24 + name.count
    let commandSize = (unpadded + 7) & ~7

    var command = Data()
    appendUInt32(&command, LC_LOAD_WEAK_DYLIB)
    appendUInt32(&command, UInt32(commandSize))
    appendUInt32(&command, 24)        // name offset within this command
    appendUInt32(&command, 0)         // timestamp
    appendUInt32(&command, 0x1_0000)  // current_version 1.0.0
    appendUInt32(&command, 0x1_0000)  // compatibility_version 1.0.0
    command.append(contentsOf: name)
    command.append(contentsOf: [UInt8](repeating: 0, count: commandSize - unpadded))
    return command
}

func resign(_ path: String) {
    let codesign = Process()
    codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    codesign.arguments = ["--force", "--sign", "-", path]
    do {
        try codesign.run()
    } catch {
        fail("could not run codesign: \(error.localizedDescription)")
    }
    codesign.waitUntilExit()
    guard codesign.terminationStatus == 0 else {
        fail("codesign failed with status \(codesign.terminationStatus)")
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fail("usage: \(URL(fileURLWithPath: arguments[0]).lastPathComponent) <path-to-winemac.so>")
}
let target = arguments[1]

guard var data = FileManager.default.contents(atPath: target) else {
    fail("could not read \(target)")
}

guard data.count >= 32, readUInt32(data, 0) == MH_MAGIC_64 else {
    fail("not a thin 64-bit Mach-O; a universal binary would need per-slice patching")
}

let commandCount = readUInt32(data, 16)
let commandsSize = readUInt32(data, 20)
let commands = loadCommands(data, count: commandCount)

if referencedDylibs(data, commands: commands).contains(dylibReference) {
    print("already patched: \(target)")
    exit(0)
}

let command = buildLoadCommand(reference: dylibReference)
let headerEnd = 32 + Int(commandsSize)
let available = firstContentOffset(data, commands: commands) - headerEnd

guard command.count <= available else {
    fail("no header padding: need \(command.count) bytes, have \(available)")
}

let paddingRange = headerEnd..<(headerEnd + command.count)
guard data[paddingRange].allSatisfy({ $0 == 0 }) else {
    fail("header padding is not zero-filled; refusing to overwrite")
}

data.replaceSubrange(paddingRange, with: command)
writeUInt32(&data, 16, commandCount + 1)
writeUInt32(&data, 20, commandsSize + UInt32(command.count))

do {
    try data.write(to: URL(fileURLWithPath: target))
} catch {
    fail("could not write \(target): \(error.localizedDescription)")
}

// Adding a load command invalidates the existing ad-hoc signature.
resign(target)

print("patched \(target): +LC_LOAD_WEAK_DYLIB \(dylibReference) "
      + "(\(command.count) bytes), re-signed")
