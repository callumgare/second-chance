//
//  SkipSynthPlayoutTests.swift
//  WineKitTests
//
//  WINE.SKIP-SYNTH-PLAYOUT's patch to Wine's 32-bit dmsynth.dll, on a DLL
//  built here byte by byte, and on the real one where an engine store on
//  this Mac has it.

import Foundation
import Testing
@testable import WineExecutor
import WindowsFormats
import WrappFormat
import WrappModuleKit

@Suite("Skip synth play-out")
struct SkipSynthPlayoutTests {
    static let imageBase = 0x1000_0000
    /// Where the fake DLL's .rdata (RVA 0x2000) holds the trace message.
    static let messageRVA = 0x2010
    static let messageAddress = imageBase + messageRVA

    /// Wine 10's play-out loop from its compare to the trace's message, as
    /// GCC laid it out: `cmp ebx, eax; jae <done>; test byte [flags], 8;
    /// je <loop>; …; mov dword [esp+0xc], <message>`, then the loop's end
    /// and what follows it, which `done` is the offset of within the code
    /// and the jump goes to, unless `target` says otherwise.
    static func loop(jump: [UInt8] = [0x0f, 0x83], done: Int = 0x80, target: Int? = nil,
                     message: Int = messageAddress, traceBit: UInt8 = 0x08) -> [UInt8] {
        var code: [UInt8] = [0x39, 0xc3]                                          // cmp ebx, eax
        let jumpAt = code.count
        code += jump + SkipSynthPlayout.littleEndian((target ?? done) - (jumpAt + 6)) // jae <done>
        code += [0xf6, 0x05] + SkipSynthPlayout.littleEndian(0x1000_9048) + [traceBit] // test byte [flags], 8
        code += [0x0f, 0x84] + SkipSynthPlayout.littleEndian(-0x93)               // je <loop>
        code += [0x89, 0x5c, 0x24, 0x1c, 0x89, 0x44, 0x24, 0x18]                 // the trace's arguments
        code += [0xc7, 0x44, 0x24, 0x0c] + SkipSynthPlayout.littleEndian(message) // mov dword [esp+0xc], <message>
        code += [0xe8, 0x00, 0x00, 0x00, 0x00]                                    // call <trace>
        code += Array(repeating: 0x90, count: done - code.count)                  // up to <done>
        code += [0x8b, 0x85, 0x98, 0xfc, 0xff, 0xff]                              // done: mov eax, [ebp-0x368]
        return code
    }

    /// A minimal 32-bit DLL: .text (RVA 0x1000) holding `code` and .rdata
    /// (0x2000) holding the trace's message at 0x2010.
    static func fakeDmsynth(code: [UInt8]? = nil, message: String = SkipSynthPlayout.message + " %#lx, play_pos %#lx") -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0xc00)
        func put16(_ offset: Int, _ value: Int) { for i in 0..<2 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xff) } }
        func put32(_ offset: Int, _ value: Int) { for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xff) } }
        func putString(_ offset: Int, _ text: String) { bytes.replaceSubrange(offset..<offset + text.utf8.count, with: Array(text.utf8)) }

        bytes[0] = 0x4d; bytes[1] = 0x5a                       // MZ
        put32(0x3c, 0x80)
        putString(0x80, "PE")
        put16(0x84, 0x14c)                                      // i386
        put16(0x86, 2)                                          // sections
        put16(0x94, 0xe0)                                       // optional header size
        let optional = 0x98
        put16(optional, 0x10b)                                  // PE32
        put32(optional + 28, imageBase)
        put32(optional + 92, 16)                                // data directories
        let sections = optional + 0xe0
        for (index, (name, rva, file)) in [(".text", 0x1000, 0x400), (".rdata", 0x2000, 0x800)].enumerated() {
            let header = sections + 40 * index
            putString(header, name)
            put32(header + 8, 0x400); put32(header + 12, rva)
            put32(header + 16, 0x400); put32(header + 20, file)
        }
        let text = code ?? loop()
        bytes.replaceSubrange(0x400..<0x400 + text.count, with: text)
        putString(0x810, message)                               // RVA 0x2010
        return bytes
    }

    @Test func findsTheMessagesAddressFromItsPlaceInTheFile() throws {
        let image = try #require(WindowsExecutable(data: Data(Self.fakeDmsynth())))
        #expect(image.rva(ofFileOffset: 0x810) == Self.messageRVA)
        #expect(image.rva(ofFileOffset: 0x404) == 0x1004)
        #expect(image.rva(ofFileOffset: 0x20) == nil)
    }

    @Test func theLoopsTestBecomesAJumpWithTheSameDisplacement() throws {
        let original = Self.fakeDmsynth()
        let (patched, outcome) = try SkipSynthPlayout.patch(Data(original))
        #expect(outcome == .patched)
        let changed = zip(original, patched).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(changed == [0x402, 0x403])
        #expect(Array(patched[0x402..<0x408]) == [0x90, 0xe9] + Array(original[0x404..<0x408]))
    }

    @Test func aPatchedDLLIsLeftAsItIs() throws {
        let (once, _) = try SkipSynthPlayout.patch(Data(Self.fakeDmsynth()))
        let (twice, outcome) = try SkipSynthPlayout.patch(once)
        #expect(outcome == .alreadyPatched)
        #expect(twice == once)
    }

    @Test func aDLLThePatchDoesntKnowIsRefused() {
        #expect(throws: SkipSynthPlayout.PatchError.notPE32) {
            try SkipSynthPlayout.patch(Data(repeating: 0, count: 64))
        }
        #expect(throws: SkipSynthPlayout.PatchError.messageMissing) {
            try SkipSynthPlayout.patch(Data(Self.fakeDmsynth(message: "Something else entirely")))
        }
        // The message passed twice: which use is the loop's isn't known.
        let twice = Self.loop() + [0xc7, 0x44, 0x24, 0x0c] + SkipSynthPlayout.littleEndian(Self.messageAddress)
        #expect(throws: SkipSynthPlayout.PatchError.messageNotUsedOnce(2)) {
            try SkipSynthPlayout.patch(Data(Self.fakeDmsynth(code: twice)))
        }
        // A jb where the jae should be.
        #expect(throws: SkipSynthPlayout.PatchError.loopTestNotFound) {
            try SkipSynthPlayout.patch(Data(Self.fakeDmsynth(code: Self.loop(jump: [0x0f, 0x82]))))
        }
        // Another channel bit than TRACE's.
        #expect(throws: SkipSynthPlayout.PatchError.loopTestNotFound) {
            try SkipSynthPlayout.patch(Data(Self.fakeDmsynth(code: Self.loop(traceBit: 0x02))))
        }
        // A test that jumps back into the loop rather than out of it.
        #expect(throws: SkipSynthPlayout.PatchError.targetBeforeMessage) {
            try SkipSynthPlayout.patch(Data(Self.fakeDmsynth(code: Self.loop(target: 0x10))))
        }
    }

    // MARK: - In a tree

    static func tree(prefixCopy: [UInt8]?) throws -> URL {
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("skip-synth-playout-\(UUID().uuidString).app")
        let engine = SkipSynthPlayout.engineDLL(in: tree)
        try FileManager.default.createDirectory(at: engine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(fakeDmsynth()).write(to: engine)
        if let prefixCopy {
            let copy = SkipSynthPlayout.prefixDLL(in: tree)
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(prefixCopy).write(to: copy)
        }
        return tree
    }

    @Test func theEngineAndThePrefixsCopyOfItArePatched() throws {
        let tree = try Self.tree(prefixCopy: Self.fakeDmsynth())
        defer { try? FileManager.default.removeItem(at: tree) }
        #expect(try SkipSynthPlayout.apply(in: tree) == .patched)
        let expected = try SkipSynthPlayout.patch(Data(Self.fakeDmsynth())).0
        #expect(try Data(contentsOf: SkipSynthPlayout.engineDLL(in: tree)) == expected)
        #expect(try Data(contentsOf: SkipSynthPlayout.prefixDLL(in: tree)) == expected)
        #expect(try SkipSynthPlayout.apply(in: tree) == .alreadyPatched)
    }

    @Test func theEngineStoresFileIsReplacedNotWrittenOver() throws {
        // The tree's engine is a clone of the store's, or a link to it.
        let tree = try Self.tree(prefixCopy: nil)
        defer { try? FileManager.default.removeItem(at: tree) }
        let engine = SkipSynthPlayout.engineDLL(in: tree)
        let store = tree.deletingLastPathComponent().appendingPathComponent("\(tree.lastPathComponent)-store.dll")
        defer { try? FileManager.default.removeItem(at: store) }
        try FileManager.default.moveItem(at: engine, to: store)
        try FileManager.default.linkItem(at: store, to: engine)
        _ = try SkipSynthPlayout.apply(in: tree)
        #expect(try Data(contentsOf: store) == Data(Self.fakeDmsynth()))
        #expect(try Data(contentsOf: engine) != Data(Self.fakeDmsynth()))
    }

    @Test func microsoftsCopyInThePrefixIsLeftAlone() throws {
        // winetricks' directmusic puts Microsoft's dmsynth.dll in syswow64.
        let microsofts = Self.fakeDmsynth(message: "Microsoft's own")
        let tree = try Self.tree(prefixCopy: microsofts)
        defer { try? FileManager.default.removeItem(at: tree) }
        _ = try SkipSynthPlayout.apply(in: tree)
        #expect(try Data(contentsOf: SkipSynthPlayout.prefixDLL(in: tree)) == Data(microsofts))
    }

    @Test func aTreeWithoutWineIsARecipeFailure() throws {
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("no-wine-\(UUID().uuidString).app")
        #expect {
            try SkipSynthPlayout.apply(in: tree)
        } throws: { error in
            guard case .recipe = error as? StepFailure else { return false }
            return true
        }
    }

    // MARK: - The real one

    /// Wine's 32-bit dmsynth.dll from an engine store on this Mac, if one has it.
    nonisolated static let realDmsynth: URL? = {
        let caches = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/SecondChance/engines")
        let shared = URL(fileURLWithPath: "/Users/Shared/second-chance/engines")
        for root in [caches, shared] {
            guard let engines = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for engine in engines.sorted(by: { $0.path < $1.path }) {
                let dll = engine.appendingPathComponent("SharedSupport/wine/lib/wine/i386-windows/dmsynth.dll")
                if FileManager.default.isReadableFile(atPath: dll.path) { return dll }
            }
        }
        return nil
    }()

    // Needs a prepared Wine in this Mac's engine store (`sc engine fetch`).
    @Test(.enabled(if: realDmsynth != nil)) func wines32BitDmsynthPatchesInTwoBytes() throws {
        let dll = try #require(Self.realDmsynth)
        let original = try Data(contentsOf: dll)
        let (patched, outcome) = try SkipSynthPlayout.patch(original)
        #expect(outcome == .patched)
        let changed = zip(original, patched).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(changed.count == 2)
        if let first = changed.first {
            #expect(Array(original[first..<first + 2]) == [0x0f, 0x83])
            #expect(Array(patched[first..<first + 2]) == [0x90, 0xe9])
        }
        #expect(try SkipSynthPlayout.patch(patched).1 == .alreadyPatched)
    }
}
