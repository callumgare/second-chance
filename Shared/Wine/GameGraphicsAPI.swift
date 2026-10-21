//
//  GameGraphicsAPI.swift
//  Shared
//
//  What a Wine game draws with, read from the DLLs its .exe imports. It
//  decides whether the wrapp arms cursor lock: a DirectDraw game draws through
//  cnc-ddraw, which swallows the player's first click unless the cursor lock
//  gets it to take the mouse first, while a Direct3D game never goes near
//  cnc-ddraw, and the cursor lock's middle clicks only get in the way — each
//  one closes a menu the player has opened from the menu bar.
//  See docs/wine-in-process-helpers.md#cursor-lock.

import Foundation

nonisolated public enum GameGraphicsAPI: Equatable, Sendable {
    /// Imports ddraw.dll, so it draws through cnc-ddraw.
    case directDraw
    /// Imports Direct3D (d3d8.dll, d3d9.dll …) and not ddraw.dll.
    case direct3D
    /// Imports neither, or the .exe couldn't be read: a game that loads its
    /// graphics DLL at run time, or a DRM wrapper that hides the imports.
    case unknown

    public init(exeAt url: URL) {
        guard let imports = WindowsExecutable.importedDLLs(at: url) else {
            self = .unknown
            return
        }
        self.init(importedDLLs: imports)
    }

    /// From the lower-cased names of the DLLs an .exe imports.
    public init(importedDLLs imports: Set<String>) {
        if imports.contains("ddraw.dll") {
            self = .directDraw
        } else if imports.contains(where: { $0.hasPrefix("d3d") && !$0.hasPrefix("d3dx") }) {
            self = .direct3D
        } else {
            self = .unknown
        }
    }

    /// Whether cnc-ddraw may be drawing the game, so it needs cursor lock.
    /// Only a game known to draw with Direct3D goes without.
    public var mayUseCncDdraw: Bool { self != .direct3D }

    /// Whether the game may draw with Direct3D, so its picture needs scaling
    /// up when Wine emulates the display mode it switches to. Only a game known
    /// to draw through cnc-ddraw, which never switches the real display, goes
    /// without.
    public var mayUseDirect3D: Bool { self != .directDraw }

    /// For a log line: "… draws with <this>".
    public var logDescription: String {
        switch self {
        case .directDraw: return "DirectDraw (through cnc-ddraw)"
        case .direct3D: return "Direct3D"
        case .unknown: return "an unknown graphics API (its .exe imports neither ddraw nor d3d)"
        }
    }
}

/// Just enough of the PE format to list an .exe's imports.
nonisolated public enum WindowsExecutable {
    /// The lower-cased names of the DLLs a PE image imports (its import
    /// directory; not delay-loaded DLLs), or nil if it isn't a PE image this
    /// can read.
    public static func importedDLLs(at url: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return importedDLLs(in: data)
    }

    public static func importedDLLs(in data: Data) -> Set<String>? {
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int? {
            guard let low = u16(offset), let high = u16(offset + 2) else { return nil }
            return low | high << 16
        }

        guard u16(0) == 0x5A4D,  // "MZ"
              let pe = u32(0x3C), u32(pe) == 0x0000_4550,  // "PE\0\0"
              let sectionCount = u16(pe + 6),
              let optionalSize = u16(pe + 20) else { return nil }
        let optional = pe + 24
        // The data directories start later in PE32+ than in PE32.
        let directories: Int
        switch u16(optional) {
        case 0x10B: directories = optional + 96
        case 0x20B: directories = optional + 112
        default: return nil
        }
        guard let directoryCount = u32(directories - 4), directoryCount > 1,
              let importRVA = u32(directories + 8), importRVA != 0 else { return [] }

        // Sections map RVAs to file offsets.
        let sectionTable = optional + optionalSize
        func fileOffset(ofRVA rva: Int) -> Int? {
            for index in 0..<sectionCount {
                let header = sectionTable + index * 40
                guard let virtualSize = u32(header + 8), let virtualAddress = u32(header + 12),
                      let rawSize = u32(header + 16), let rawOffset = u32(header + 20) else { return nil }
                let size = max(virtualSize, rawSize)
                if rva >= virtualAddress, rva < virtualAddress + size {
                    return rawOffset + (rva - virtualAddress)
                }
            }
            return nil
        }
        func cString(atRVA rva: Int) -> String? {
            guard var offset = fileOffset(ofRVA: rva) else { return nil }
            var characters: [UInt8] = []
            while offset < bytes.count, bytes[offset] != 0, characters.count < 256 {
                characters.append(bytes[offset])
                offset += 1
            }
            return String(bytes: characters, encoding: .ascii)
        }

        guard var descriptor = fileOffset(ofRVA: importRVA) else { return nil }
        var names: Set<String> = []
        // Import descriptors, 20 bytes each, ending with an all-zero one. Capped
        // in case a damaged file never ends the list.
        for _ in 0..<1024 {
            guard let lookup = u32(descriptor), let nameRVA = u32(descriptor + 12),
                  let addresses = u32(descriptor + 16) else { break }
            if lookup == 0 && nameRVA == 0 && addresses == 0 { break }
            if let name = cString(atRVA: nameRVA) { names.insert(name.lowercased()) }
            descriptor += 20
        }
        return names
    }
}
