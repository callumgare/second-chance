//
//  RosettaFaultFix.swift
//  WrappBuilder
//
//  Patches Wine's 32-bit ntdll.dll so that two kinds of fault Rosetta 2 raises
//  where Windows wouldn't are dealt with before any exception handler sees
//  them: an fs: access with the 0x67 address-size prefix, which Rosetta can't
//  run, and the Windows 9x SoftICE probes (int 68h, int 41h), which code takes
//  because Wine on macOS runs 32-bit code in an LDT segment. Armadillo, the DRM
//  on Big Fish's games, trips over both. Packages/WrappBuilder/RosettaFaultFix/fault_fix.c
//  is the code that does it; docs/big-fish.md#armadillo-under-rosetta has why.
//
//  Wine is patched once, as it is prepared (`WineBuild.prepare`), so every
//  Wine program a wrapp or a build runs has it.

import Foundation

/// Adds fault_fix.c's code to a 32-bit Wine ntdll.dll, called first thing in
/// `KiUserExceptionDispatcher`.
///
/// The code goes into the unused end of `.text`'s last file page. The
/// dispatcher's first instructions (`push [esp+4]` twice: the record and the
/// context) become a jump to a short stub that calls the code; if it handled
/// the fault the stub resumes the thread with `NtContinue`, and otherwise it
/// does the two pushes and jumps back into the dispatcher.
public nonisolated enum RosettaFaultFix {
    public enum Outcome: Equatable, Sendable {
        case patched
        case alreadyPatched
    }

    public enum PatchError: Error, Equatable, CustomStringConvertible {
        case notPE32
        case exportMissing(String)
        case unexpectedEntry([UInt8])
        case noRoom
        case areaInUse

        public var description: String {
            switch self {
            case .notPE32: "not a 32-bit PE file"
            case .exportMissing(let name): "no export named \(name)"
            case .unexpectedEntry(let bytes):
                "KiUserExceptionDispatcher starts with \(bytes.map { String(format: "%02x", $0) }.joined()), not two pushes"
            case .noRoom: "no room left in .text"
            case .areaInUse: "the end of .text isn't empty"
            }
        }
    }

    /// `push dword [esp+4]`, twice: what KiUserExceptionDispatcher starts with.
    static let entryPushes: [UInt8] = [0xff, 0x74, 0x24, 0x04, 0xff, 0x74, 0x24, 0x04]

    /// Returns `dll` with the fix added, or unchanged if it already has it.
    public static func patch(_ dll: Data) throws -> (Data, Outcome) {
        var bytes = [UInt8](dll)
        let image = try PEImage(bytes)
        guard let dispatcher = image.exports["KiUserExceptionDispatcher"] else {
            throw PatchError.exportMissing("KiUserExceptionDispatcher")
        }
        guard let ntContinue = image.exports["NtContinue"] else { throw PatchError.exportMissing("NtContinue") }
        guard let entry = image.fileOffset(dispatcher), entry + 8 <= bytes.count else { throw PatchError.notPE32 }

        let first = Array(bytes[entry..<entry + 8])
        if first[0] == 0xe9, isOurStub(at: dispatcher + 5 + Int(readInt32(bytes, entry + 1)), in: bytes, image: image) {
            return (dll, .alreadyPatched)
        }
        guard first == entryPushes else { throw PatchError.unexpectedEntry(first) }

        guard let text = image.sections.first(where: { $0.name == ".text" }) else { throw PatchError.notPE32 }
        let caveRVA = (text.virtualAddress + text.virtualSize + 15) & ~15
        let cave = stub(at: caveRVA, dispatcher: dispatcher, ntContinue: ntContinue)
        guard caveRVA + cave.count <= text.virtualAddress + text.rawSize,
              let caveOffset = image.fileOffset(caveRVA) else { throw PatchError.noRoom }
        guard bytes[caveOffset..<caveOffset + cave.count].allSatisfy({ $0 == 0 }) else { throw PatchError.areaInUse }

        bytes.replaceSubrange(caveOffset..<caveOffset + cave.count, with: cave)
        // .text's VirtualSize now covers the code, so the loader maps it.
        writeInt32(&bytes, text.headerOffset + 8, Int32(caveRVA + cave.count - text.virtualAddress))
        bytes.replaceSubrange(entry..<entry + 8, with: [0xe9] + rel32(from: dispatcher + 5, to: caveRVA) + [0x90, 0x90, 0x90])
        return (Data(bytes), .patched)
    }

    /// The stub and the code, as placed at `rva`.
    static func stub(at rva: Int, dispatcher: Int, ntContinue: Int) -> [UInt8] {
        var stub = entryPushes                                  // the record and context, as arguments
        let callFix = stub.count
        stub += [0xe8, 0, 0, 0, 0]                              // call bf_fault_fix
        stub += [0x85, 0xc0]                                    // test eax, eax
        stub += [0x74, 0x0c]                                    // jz dispatch
        stub += [0x8b, 0x4c, 0x24, 0x04]                        // mov ecx, [esp+4] (the context)
        stub += [0x6a, 0x00]                                    // push 0 (not alertable)
        stub += [0x51]                                          // push ecx
        let callContinue = stub.count
        stub += [0xe8, 0, 0, 0, 0]                              // call NtContinue (doesn't return)
        stub += entryPushes                                     // dispatch: what the entry did
        let jumpBack = stub.count
        stub += [0xe9, 0, 0, 0, 0]                              // jmp past the entry's pushes
        let codeOffset = (stub.count + 15) & ~15
        stub += [UInt8](repeating: 0xcc, count: codeOffset - stub.count)
        stub.replaceSubrange(callFix + 1..<callFix + 5, with: rel32(from: rva + callFix + 5, to: rva + codeOffset))
        stub.replaceSubrange(callContinue + 1..<callContinue + 5, with: rel32(from: rva + callContinue + 5, to: ntContinue))
        stub.replaceSubrange(jumpBack + 1..<jumpBack + 5, with: rel32(from: rva + jumpBack + 5, to: dispatcher + 8))
        return stub + code
    }

    private static func isOurStub(at rva: Int, in bytes: [UInt8], image: PEImage) -> Bool {
        guard let offset = image.fileOffset(rva), offset + 9 <= bytes.count else { return false }
        return Array(bytes[offset..<offset + 8]) == entryPushes && bytes[offset + 8] == 0xe8
    }

    private static func rel32(from next: Int, to target: Int) -> [UInt8] {
        let value = UInt32(bitPattern: Int32(truncatingIfNeeded: target - next))
        return (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    fileprivate static func readInt32(_ bytes: [UInt8], _ offset: Int) -> Int32 {
        Int32(bitPattern: (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) })
    }

    private static func writeInt32(_ bytes: inout [UInt8], _ offset: Int, _ value: Int32) {
        let raw = UInt32(bitPattern: value)
        for byte in 0..<4 { bytes[offset + byte] = UInt8(truncatingIfNeeded: raw >> (8 * UInt32(byte))) }
    }

    /// fault_fix.c compiled by Packages/WrappBuilder/RosettaFaultFix/regenerate.sh:
    /// `int __stdcall bf_fault_fix(const u32 *record, u8 *context)`.
    static let code: [UInt8] = [
        0x83, 0xec, 0x08, 0x8b, 0x44, 0x24, 0x0c, 0x81, 0x38, 0x05, 0x00, 0x00,
        0xc0, 0x0f, 0x85, 0x8e, 0x00, 0x00, 0x00, 0x89, 0x1c, 0x24, 0x8b, 0x5c,
        0x24, 0x10, 0x8b, 0x93, 0xb8, 0x00, 0x00, 0x00, 0x0f, 0xb6, 0x0a, 0x80,
        0xf9, 0xcd, 0x74, 0x68, 0x80, 0xf9, 0x64, 0x75, 0x71, 0x80, 0x7a, 0x01,
        0x67, 0x75, 0x6b, 0x89, 0x74, 0x24, 0x04, 0x0f, 0xb6, 0x42, 0x02, 0x64,
        0x8b, 0x1d, 0x18, 0x00, 0x00, 0x00, 0x89, 0xc1, 0x89, 0xde, 0x83, 0xe1,
        0xfd, 0x80, 0xf9, 0xa1, 0x0f, 0x85, 0x8e, 0x00, 0x00, 0x00, 0x0f, 0xb7,
        0x4a, 0x03, 0x01, 0xd9, 0x3c, 0xa1, 0x0f, 0x84, 0xe0, 0x00, 0x00, 0x00,
        0x8b, 0x44, 0x24, 0x10, 0x8b, 0x80, 0xb0, 0x00, 0x00, 0x00, 0x89, 0x01,
        0x8b, 0x44, 0x24, 0x10, 0x8b, 0x90, 0xb8, 0x00, 0x00, 0x00, 0xb8, 0x05,
        0x00, 0x00, 0x00, 0x01, 0xd0, 0x8b, 0x54, 0x24, 0x10, 0x8b, 0x74, 0x24,
        0x04, 0x89, 0x82, 0xb8, 0x00, 0x00, 0x00, 0xeb, 0x43, 0x8d, 0x76, 0x00,
        0x0f, 0xb6, 0x4a, 0x01, 0x80, 0xf9, 0x68, 0x74, 0x17, 0x80, 0xf9, 0x41,
        0x74, 0x12, 0x8b, 0x1c, 0x24, 0x31, 0xc0, 0x83, 0xc4, 0x08, 0xc2, 0x08,
        0x00, 0x8d, 0xb4, 0x26, 0x00, 0x00, 0x00, 0x00, 0x8b, 0x48, 0x14, 0x85,
        0xc9, 0x75, 0xe7, 0x83, 0x78, 0x18, 0xff, 0x75, 0xe1, 0x8b, 0x44, 0x24,
        0x10, 0x83, 0xc2, 0x02, 0x89, 0x90, 0xb8, 0x00, 0x00, 0x00, 0x8d, 0xb6,
        0x00, 0x00, 0x00, 0x00, 0x8b, 0x1c, 0x24, 0xb8, 0x01, 0x00, 0x00, 0x00,
        0xeb, 0xc9, 0x8d, 0xb6, 0x00, 0x00, 0x00, 0x00, 0x0f, 0xb6, 0x4a, 0x03,
        0x89, 0xcb, 0x83, 0xe3, 0xc7, 0x80, 0xfb, 0x06, 0x75, 0x42, 0x0f, 0xb7,
        0x52, 0x04, 0xc0, 0xe9, 0x03, 0x01, 0xf2, 0x3c, 0x8f, 0x75, 0x65, 0x84,
        0xc9, 0x75, 0x61, 0x8b, 0x44, 0x24, 0x10, 0x8b, 0x80, 0xc4, 0x00, 0x00,
        0x00, 0x8b, 0x00, 0x89, 0x02, 0x8b, 0x44, 0x24, 0x10, 0x83, 0x80, 0xc4,
        0x00, 0x00, 0x00, 0x04, 0x8b, 0x90, 0xb8, 0x00, 0x00, 0x00, 0xb8, 0x06,
        0x00, 0x00, 0x00, 0xe9, 0x53, 0xff, 0xff, 0xff, 0x2e, 0x8d, 0xb4, 0x26,
        0x00, 0x00, 0x00, 0x00, 0x8b, 0x1c, 0x24, 0x8b, 0x74, 0x24, 0x04, 0xe9,
        0x65, 0xff, 0xff, 0xff, 0x8d, 0x74, 0x26, 0x00, 0x8b, 0x01, 0x8b, 0x5c,
        0x24, 0x10, 0x89, 0x83, 0xb0, 0x00, 0x00, 0x00, 0xb8, 0x05, 0x00, 0x00,
        0x00, 0xe9, 0x25, 0xff, 0xff, 0xff, 0x66, 0x90, 0x2e, 0x8d, 0xb4, 0x26,
        0x00, 0x00, 0x00, 0x00, 0x3c, 0xff, 0x75, 0x31, 0x80, 0xf9, 0x06, 0x75,
        0x2c, 0x8b, 0x44, 0x24, 0x10, 0x8b, 0x5c, 0x24, 0x10, 0x8b, 0x80, 0xc4,
        0x00, 0x00, 0x00, 0x8d, 0x48, 0xfc, 0x89, 0x8b, 0xc4, 0x00, 0x00, 0x00,
        0x8b, 0x12, 0x89, 0x50, 0xfc, 0xb8, 0x06, 0x00, 0x00, 0x00, 0x8b, 0x93,
        0xb8, 0x00, 0x00, 0x00, 0xe9, 0xe6, 0xfe, 0xff, 0xff, 0x3c, 0x89, 0x74,
        0x31, 0x3c, 0x8b, 0x75, 0x93, 0xb8, 0x9c, 0x00, 0x00, 0x00, 0x80, 0xf9,
        0x07, 0x74, 0x0a, 0x0f, 0xb6, 0xc9, 0x8b, 0x04, 0x8d, 0x00, 0x00, 0x00,
        0x00, 0x8b, 0x12, 0x8b, 0x5c, 0x24, 0x10, 0x89, 0x14, 0x03, 0xb8, 0x06,
        0x00, 0x00, 0x00, 0x8b, 0x93, 0xb8, 0x00, 0x00, 0x00, 0xe9, 0xb1, 0xfe,
        0xff, 0xff, 0xb8, 0x9c, 0x00, 0x00, 0x00, 0x80, 0xf9, 0x07, 0x74, 0x0a,
        0x0f, 0xb6, 0xc9, 0x8b, 0x04, 0x8d, 0x00, 0x00, 0x00, 0x00, 0x8b, 0x5c,
        0x24, 0x10, 0x8b, 0x04, 0x03, 0x89, 0x02, 0xb8, 0x06, 0x00, 0x00, 0x00,
        0x8b, 0x93, 0xb8, 0x00, 0x00, 0x00, 0xe9, 0x84, 0xfe, 0xff, 0xff, 0x90,
        0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90,
    ]
}

/// What the patch needs of a PE file: its sections and named exports.
nonisolated struct PEImage {
    struct Section {
        let name: String
        let headerOffset: Int
        let virtualSize: Int
        let virtualAddress: Int
        let rawSize: Int
        let rawPointer: Int
    }

    let sections: [Section]
    let exports: [String: Int]

    init(_ bytes: [UInt8]) throws {
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= bytes.count else { throw RosettaFaultFix.PatchError.notPE32 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 4 <= bytes.count else { throw RosettaFaultFix.PatchError.notPE32 }
            return Int(RosettaFaultFix.readInt32(bytes, offset)) & 0xffff_ffff
        }

        guard bytes.count > 0x40, bytes[0] == 0x4d, bytes[1] == 0x5a else { throw RosettaFaultFix.PatchError.notPE32 }
        let pe = try u32(0x3c)
        guard try u32(pe) == 0x4550 else { throw RosettaFaultFix.PatchError.notPE32 }
        let optional = pe + 24
        guard try u16(optional) == 0x10b else { throw RosettaFaultFix.PatchError.notPE32 }  // PE32, not PE32+
        let sectionCount = try u16(pe + 6)
        let optionalSize = try u16(pe + 20)

        var sections: [Section] = []
        for index in 0..<sectionCount {
            let header = optional + optionalSize + 40 * index
            let rawName = bytes[header..<min(header + 8, bytes.count)].prefix { $0 != 0 }
            sections.append(Section(
                name: String(decoding: rawName, as: UTF8.self),
                headerOffset: header,
                virtualSize: try u32(header + 8),
                virtualAddress: try u32(header + 12),
                rawSize: try u32(header + 16),
                rawPointer: try u32(header + 20)
            ))
        }
        self.sections = sections

        func offset(_ rva: Int) -> Int? {
            sections.first { $0.virtualAddress <= rva && rva < $0.virtualAddress + max($0.virtualSize, $0.rawSize) }
                .map { $0.rawPointer + rva - $0.virtualAddress }
        }

        var exports: [String: Int] = [:]
        let exportRVA = try u32(optional + 96)
        if exportRVA != 0, let directory = offset(exportRVA) {
            let nameCount = try u32(directory + 24)
            let functions = try u32(directory + 28), names = try u32(directory + 32), ordinals = try u32(directory + 36)
            if let functionTable = offset(functions), let nameTable = offset(names), let ordinalTable = offset(ordinals) {
                for index in 0..<nameCount {
                    guard let nameOffset = offset(try u32(nameTable + 4 * index)) else { continue }
                    let end = bytes[nameOffset...].firstIndex(of: 0) ?? bytes.count
                    let name = String(decoding: bytes[nameOffset..<end], as: UTF8.self)
                    let ordinal = try u16(ordinalTable + 2 * index)
                    exports[name] = try u32(functionTable + 4 * ordinal)
                }
            }
        }
        self.exports = exports
    }

    func fileOffset(_ rva: Int) -> Int? {
        sections.first { $0.virtualAddress <= rva && rva < $0.virtualAddress + max($0.virtualSize, $0.rawSize) }
            .map { $0.rawPointer + rva - $0.virtualAddress }
    }
}
