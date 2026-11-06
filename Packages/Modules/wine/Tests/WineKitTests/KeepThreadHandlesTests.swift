//
//  KeepThreadHandlesTests.swift
//  WineKitTests
//
//  WINE.KEEP-THREAD-HANDLES' patch to Wine's 32-bit msvcrt.dll, on a DLL
//  built here byte by byte, and on the real one where an engine store on
//  this Mac has it.

import Foundation
import Testing
@testable import WineExecutor
import WindowsFormats
import WrappFormat
import WrappModuleKit

@Suite("Keep thread handles")
struct KeepThreadHandlesTests {
    static let imageBase = 0x1000_0000
    /// kernel32's CloseHandle's import slot in the fake DLL.
    static let closeHandleSlot = 0x2064

    /// Wine 10's `_endthread` from its first instruction to the call's
    /// `push eax`, with the call through `slot` (an absolute address).
    static func endthread(slot: Int, next: UInt8 = 0x50, calls: Int = 1) -> [UInt8] {
        let address = KeepThreadHandles.littleEndian(slot)
        var code: [UInt8] = [0x55, 0x89, 0xe5, 0x53, 0x83, 0xec, 0x18]   // push ebp; mov ebp,esp; push ebx; sub esp,0x18
        code += [0x8b, 0x40, 0x04, 0x83, 0xf8, 0xff, 0x74, 0x1d]          // mov eax,[eax+4]; cmp eax,-1; je …
        for _ in 0..<calls {
            code += [0x89, 0x04, 0x24]                                     // mov [esp],eax
            code += [0xff, 0x15] + address                                 // call [CloseHandle]
            code += [next]                                                 // push eax
        }
        code += [0xc7, 0x43, 0x04, 0xff, 0xff, 0xff, 0xff]                // mov dword [ebx+4],-1
        return code
    }

    /// A minimal 32-bit DLL: .text (RVA 0x1000) holding `_endthread` at
    /// 0x1000 and `_endthreadex` at 0x1100, .idata (0x2000) importing Beep
    /// and CloseHandle from kernel32.dll, and .edata (0x3000) exporting both
    /// functions.
    static func fakeMsvcrt(endthread code: [UInt8]? = nil, importsCloseHandle: Bool = true) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0x1000)
        func put16(_ offset: Int, _ value: Int) { for i in 0..<2 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xff) } }
        func put32(_ offset: Int, _ value: Int) { for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xff) } }
        func putString(_ offset: Int, _ text: String) { bytes.replaceSubrange(offset..<offset + text.utf8.count, with: Array(text.utf8)) }

        bytes[0] = 0x4d; bytes[1] = 0x5a                       // MZ
        put32(0x3c, 0x80)
        putString(0x80, "PE")
        put16(0x84, 0x14c)                                      // i386
        put16(0x86, 3)                                          // sections
        put16(0x94, 0xe0)                                       // optional header size
        let optional = 0x98
        put16(optional, 0x10b)                                  // PE32
        put32(optional + 28, imageBase)
        put32(optional + 92, 16)                                // data directories
        put32(optional + 96, 0x3000); put32(optional + 100, 0x100)   // exports
        put32(optional + 104, 0x2000); put32(optional + 108, 0x100)  // imports
        let sections = optional + 0xe0
        for (index, (name, rva, file)) in [(".text", 0x1000, 0x400), (".idata", 0x2000, 0x800), (".edata", 0x3000, 0xc00)].enumerated() {
            let header = sections + 40 * index
            putString(header, name)
            put32(header + 8, 0x400); put32(header + 12, rva)
            put32(header + 16, 0x400); put32(header + 20, file)
        }

        let text = code ?? endthread(slot: imageBase + closeHandleSlot)
        bytes.replaceSubrange(0x400..<0x400 + text.count, with: text)
        bytes.replaceSubrange(0x500..<0x503, with: [0x55, 0x89, 0xe5])      // _endthreadex

        let idata = 0x800                                       // file offset of RVA 0x2000
        put32(idata + 0, 0x2040)                                // the lookup table
        put32(idata + 12, 0x20b0)                               // "kernel32.dll"
        put32(idata + 16, 0x2060)                               // the address table
        put32(idata + 0x40, 0x2080); put32(idata + 0x44, 0x2090)
        put32(idata + 0x60, 0x2080); put32(idata + 0x64, 0x2090)
        putString(idata + 0x82, "Beep")
        putString(idata + 0x92, importsCloseHandle ? "CloseHandle" : "CreateFileA")
        putString(idata + 0xb0, "KERNEL32.dll")

        let edata = 0xc00                                       // file offset of RVA 0x3000
        put32(edata + 20, 2); put32(edata + 24, 2)
        put32(edata + 28, 0x3040); put32(edata + 32, 0x3050); put32(edata + 36, 0x3060)
        put32(edata + 0x40, 0x1000); put32(edata + 0x44, 0x1100)
        put32(edata + 0x50, 0x3080); put32(edata + 0x54, 0x30a0)
        put16(edata + 0x60, 0); put16(edata + 0x62, 1)
        putString(edata + 0x80, "_endthread")
        putString(edata + 0xa0, "_endthreadex")
        return bytes
    }

    @Test func findsTheExportsAndTheImportSlot() throws {
        let image = try #require(WindowsExecutable(data: Data(Self.fakeMsvcrt())))
        #expect(image.imageBase == Self.imageBase)
        #expect(image.exports == ["_endthread": 0x1000, "_endthreadex": 0x1100])
        #expect(image.importSlot(of: "CloseHandle", from: "kernel32.dll") == Self.closeHandleSlot)
        #expect(image.importSlot(of: "Beep", from: "KERNEL32.DLL") == Self.closeHandleSlot - 4)
        #expect(image.importSlot(of: "CloseHandle", from: "ntdll.dll") == nil)
        #expect(image.fileOffset(ofRVA: 0x1000) == 0x400)
    }

    @Test func theCallBecomesAPopAndATestOfTheSameAddress() throws {
        let original = Self.fakeMsvcrt()
        let (data, outcome) = try KeepThreadHandles.patch(Data(original))
        #expect(outcome == .patched)
        let patched = [UInt8](data)
        let call = 0x400 + 15 + 3                               // after the prologue and mov [esp],eax
        #expect(Array(original[call..<call + 2]) == [0xff, 0x15])
        #expect(Array(patched[call..<call + 2]) == [0x59, 0xa9])
        // Nothing else changes: the address stays, for its relocation.
        let changed = zip(original, patched).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(changed == [call, call + 1])
        #expect(Array(patched[call + 2..<call + 6]) == KeepThreadHandles.littleEndian(Self.imageBase + Self.closeHandleSlot))
    }

    @Test func patchingAgainChangesNothing() throws {
        let (once, _) = try KeepThreadHandles.patch(Data(Self.fakeMsvcrt()))
        let (twice, outcome) = try KeepThreadHandles.patch(once)
        #expect(outcome == .alreadyPatched)
        #expect(twice == once)
    }

    @Test func aDLLItDoesntKnowFailsRatherThanBeingPatchedBlind() {
        let slot = Self.imageBase + Self.closeHandleSlot
        #expect(throws: KeepThreadHandles.PatchError.callNotFound) {
            try KeepThreadHandles.patch(Data(Self.fakeMsvcrt(endthread: Self.endthread(slot: slot + 4))))
        }
        #expect(throws: KeepThreadHandles.PatchError.severalCalls(2)) {
            try KeepThreadHandles.patch(Data(Self.fakeMsvcrt(endthread: Self.endthread(slot: slot, calls: 2))))
        }
        // test eax,eax: the result is used, so it can't simply vanish.
        #expect(throws: KeepThreadHandles.PatchError.resultUsed(0x85)) {
            try KeepThreadHandles.patch(Data(Self.fakeMsvcrt(endthread: Self.endthread(slot: slot, next: 0x85))))
        }
        #expect(throws: KeepThreadHandles.PatchError.importMissing("CloseHandle")) {
            try KeepThreadHandles.patch(Data(Self.fakeMsvcrt(importsCloseHandle: false)))
        }
        #expect(throws: KeepThreadHandles.PatchError.notPE32) {
            try KeepThreadHandles.patch(Data(repeating: 0, count: 64))
        }
    }

    @Test func aCallInTheNextFunctionIsntTaken() throws {
        // _endthread with no call, _endthreadex (the next export) with one.
        var bytes = Self.fakeMsvcrt(endthread: [0x55, 0x89, 0xe5, 0xc3])
        let call = [0xff, 0x15] + KeepThreadHandles.littleEndian(Self.imageBase + Self.closeHandleSlot) + [0x50]
        bytes.replaceSubrange(0x510..<0x510 + call.count, with: call)
        #expect(throws: KeepThreadHandles.PatchError.callNotFound) { try KeepThreadHandles.patch(Data(bytes)) }
    }

    // MARK: - In a tree

    static func tree(prefixCopy: [UInt8]?) throws -> URL {
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("keep-thread-handles-\(UUID().uuidString).app")
        let engine = KeepThreadHandles.engineDLL(in: tree)
        try FileManager.default.createDirectory(at: engine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(fakeMsvcrt()).write(to: engine)
        if let prefixCopy {
            let copy = KeepThreadHandles.prefixDLL(in: tree)
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(prefixCopy).write(to: copy)
        }
        return tree
    }

    @Test func theEngineAndThePrefixsCopyOfItArePatched() throws {
        let tree = try Self.tree(prefixCopy: Self.fakeMsvcrt())
        defer { try? FileManager.default.removeItem(at: tree) }
        #expect(try KeepThreadHandles.apply(in: tree) == .patched)
        let expected = try KeepThreadHandles.patch(Data(Self.fakeMsvcrt())).0
        #expect(try Data(contentsOf: KeepThreadHandles.engineDLL(in: tree)) == expected)
        #expect(try Data(contentsOf: KeepThreadHandles.prefixDLL(in: tree)) == expected)
        #expect(try KeepThreadHandles.apply(in: tree) == .alreadyPatched)
    }

    @Test func theEngineStoresFileIsReplacedNotWrittenOver() throws {
        // The tree's engine is a clone of the store's, or a link to it.
        let tree = try Self.tree(prefixCopy: nil)
        defer { try? FileManager.default.removeItem(at: tree) }
        let engine = KeepThreadHandles.engineDLL(in: tree)
        let store = tree.deletingLastPathComponent().appendingPathComponent("\(tree.lastPathComponent)-store.dll")
        defer { try? FileManager.default.removeItem(at: store) }
        try FileManager.default.moveItem(at: engine, to: store)
        try FileManager.default.linkItem(at: store, to: engine)
        _ = try KeepThreadHandles.apply(in: tree)
        #expect(try Data(contentsOf: store) == Data(Self.fakeMsvcrt()))
        #expect(try Data(contentsOf: engine) != Data(Self.fakeMsvcrt()))
    }

    @Test func aPrefixCopyThatIsntWinesIsLeftAlone() throws {
        let other = Self.fakeMsvcrt(endthread: [0x55, 0x89, 0xe5, 0xc3])
        let tree = try Self.tree(prefixCopy: other)
        defer { try? FileManager.default.removeItem(at: tree) }
        _ = try KeepThreadHandles.apply(in: tree)
        #expect(try Data(contentsOf: KeepThreadHandles.prefixDLL(in: tree)) == Data(other))
    }

    @Test func aTreeWithoutWineIsARecipeFailure() throws {
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("no-wine-\(UUID().uuidString).app")
        #expect {
            try KeepThreadHandles.apply(in: tree)
        } throws: { error in
            guard case .recipe = error as? StepFailure else { return false }
            return true
        }
    }

    // MARK: - The real one

    /// Wine's 32-bit msvcrt.dll from an engine store on this Mac, if one has it.
    nonisolated static let realMsvcrt: URL? = {
        let caches = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/SecondChance/engines")
        let shared = URL(fileURLWithPath: "/Users/Shared/second-chance/engines")
        for root in [caches, shared] {
            guard let engines = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for engine in engines.sorted(by: { $0.path < $1.path }) {
                let dll = engine.appendingPathComponent("SharedSupport/wine/lib/wine/i386-windows/msvcrt.dll")
                if FileManager.default.isReadableFile(atPath: dll.path) { return dll }
            }
        }
        return nil
    }()

    // Needs a prepared Wine in this Mac's engine store (`sc engine fetch`).
    @Test(.enabled(if: realMsvcrt != nil)) func wines32BitMsvcrtPatchesInTwoBytes() throws {
        let dll = try #require(Self.realMsvcrt)
        let original = try Data(contentsOf: dll)
        let (patched, outcome) = try KeepThreadHandles.patch(original)
        #expect(outcome == .patched)
        let changed = zip(original, patched).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(changed.count == 2)
        if let first = changed.first {
            #expect(Array(patched[first..<first + 2]) == [0x59, 0xa9])
        }
        #expect(try KeepThreadHandles.patch(patched).1 == .alreadyPatched)
    }
}
