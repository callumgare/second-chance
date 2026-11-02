import Foundation
@testable import SecondChanceKit
import Testing

@Suite("Rosetta fault fix")
struct RosettaFaultFixTests {
    /// A minimal 32-bit DLL: .text (0x1000, 0x100 used of a 0x1000 file page)
    /// holding NtContinue at 0x1000 and KiUserExceptionDispatcher at 0x1040, and
    /// .edata (0x2000) exporting both.
    static func fakeNtdll(entry: [UInt8] = RosettaFaultFix.entryPushes + [0xe8, 0, 0, 0, 0, 0xcc],
                          textVirtualSize: Int = 0x100) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0x1600)
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
        put32(optional + 96, 0x2000)                            // export directory
        put32(optional + 100, 0x100)
        let sections = optional + 0xe0
        putString(sections, ".text")
        put32(sections + 8, textVirtualSize); put32(sections + 12, 0x1000)
        put32(sections + 16, 0x1000); put32(sections + 20, 0x400)
        putString(sections + 40, ".edata")
        put32(sections + 48, 0x100); put32(sections + 52, 0x2000)
        put32(sections + 56, 0x200); put32(sections + 60, 0x1400)

        bytes.replaceSubrange(0x400..<0x405, with: [0xb8, 0x1c, 0, 0, 0])           // NtContinue
        bytes.replaceSubrange(0x440..<0x440 + entry.count, with: entry)             // KiUserExceptionDispatcher

        let edata = 0x1400                                      // file offset of RVA 0x2000
        put32(edata + 20, 2); put32(edata + 24, 2)
        put32(edata + 28, 0x2040); put32(edata + 32, 0x2050); put32(edata + 36, 0x2060)
        put32(edata + 0x40, 0x1040); put32(edata + 0x44, 0x1000)
        put32(edata + 0x50, 0x2080); put32(edata + 0x54, 0x20a0)
        put16(edata + 0x60, 0); put16(edata + 0x62, 1)
        putString(edata + 0x80, "KiUserExceptionDispatcher")
        putString(edata + 0xa0, "NtContinue")
        return bytes
    }

    static func rel32Target(_ bytes: [UInt8], at offset: Int, rva: Int) -> Int {
        let raw = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + 1 + $1]) << (8 * UInt32($1)) }
        return rva + 5 + Int(Int32(bitPattern: raw))
    }

    @Test func reachesTheExportsItNeeds() throws {
        let image = try PEImage(Self.fakeNtdll())
        #expect(image.exports["KiUserExceptionDispatcher"] == 0x1040)
        #expect(image.exports["NtContinue"] == 0x1000)
        #expect(image.fileOffset(0x1040) == 0x440)
    }

    @Test func jumpsFromTheDispatcherToTheFixAndBack() throws {
        let (data, outcome) = try RosettaFaultFix.patch(Data(Self.fakeNtdll()))
        #expect(outcome == .patched)
        let bytes = [UInt8](data)

        // The entry jumps to the end of what .text used, rounded up to 16.
        #expect(bytes[0x440] == 0xe9)
        let cave = Self.rel32Target(bytes, at: 0x440, rva: 0x1040)
        #expect(cave == 0x1100)
        #expect(Array(bytes[0x445..<0x448]) == [0x90, 0x90, 0x90])

        let stub = 0x400 + cave - 0x1000
        #expect(Array(bytes[stub..<stub + 8]) == RosettaFaultFix.entryPushes)
        // call fix → the code, 16-byte aligned after the stub.
        let fix = Self.rel32Target(bytes, at: stub + 8, rva: cave + 8)
        #expect(fix % 16 == 0 && fix > cave)
        #expect(Array(bytes[(0x400 + fix - 0x1000)...].prefix(RosettaFaultFix.code.count)) == RosettaFaultFix.code)
        // call NtContinue, then the original pushes and a jump past them.
        #expect(Self.rel32Target(bytes, at: stub + 24, rva: cave + 24) == 0x1000)
        #expect(Array(bytes[stub + 29..<stub + 37]) == RosettaFaultFix.entryPushes)
        #expect(Self.rel32Target(bytes, at: stub + 37, rva: cave + 37) == 0x1048)

        // .text's virtual size grows to cover it.
        let image = try PEImage(bytes)
        let text = try #require(image.sections.first { $0.name == ".text" })
        #expect(text.virtualSize == fix + RosettaFaultFix.code.count - 0x1000)
    }

    @Test func leavesAPatchedFileAlone() throws {
        let (once, _) = try RosettaFaultFix.patch(Data(Self.fakeNtdll()))
        let (twice, outcome) = try RosettaFaultFix.patch(once)
        #expect(outcome == .alreadyPatched)
        #expect(twice == once)
    }

    @Test func refusesADispatcherItDoesNotRecognise() {
        let entry: [UInt8] = [0x55, 0x89, 0xe5, 0x83, 0xec, 0x08, 0x90, 0x90]
        #expect(throws: RosettaFaultFix.PatchError.unexpectedEntry(entry)) {
            try RosettaFaultFix.patch(Data(Self.fakeNtdll(entry: entry)))
        }
    }

    @Test func refusesWhenTextHasNoRoomLeft() {
        #expect(throws: RosettaFaultFix.PatchError.noRoom) {
            try RosettaFaultFix.patch(Data(Self.fakeNtdll(textVirtualSize: 0xf00)))
        }
    }

    @Test func refusesWhatIsNotA32BitPE() {
        #expect(throws: RosettaFaultFix.PatchError.notPE32) {
            try RosettaFaultFix.patch(Data(repeating: 0, count: 0x200))
        }
        var pe32Plus = Self.fakeNtdll()
        pe32Plus[0x98] = 0x0b; pe32Plus[0x99] = 0x02
        #expect(throws: RosettaFaultFix.PatchError.notPE32) {
            try RosettaFaultFix.patch(Data(pe32Plus))
        }
    }

    /// The code is copied into ntdll as raw bytes, so it has to end in the
    /// stdcall return for its two arguments, as regenerate.sh's compiler made it.
    @Test func codeIsAStdcallFunctionOfTwoArguments() {
        #expect(RosettaFaultFix.code.count > 64)
        let ret8: [UInt8] = [0xc2, 0x08, 0x00]
        #expect(RosettaFaultFix.code.indices.contains { RosettaFaultFix.code[$0...].starts(with: ret8) })
    }
}
