//
//  KeepThreadHandles.swift
//  WineExecutor
//
//  WINE.PATCH keep-thread-handles: Wine's 32-bit msvcrt.dll changed so that a
//  thread `_beginthread` started keeps its handle when it ends, for a game
//  that waits on that handle after the thread may already have ended.
//
//  The C runtime closes a `_beginthread` thread's handle itself as the thread
//  returns (Wine's `_beginthread_trampoline` → `_endthread` →
//  `CloseHandle(tls->handle)`, as Windows's does). Allegro 4's Windows timer
//  (`remove_timer`) sets its stop event and then waits, without limit, on the
//  timer thread's handle: when the thread has ended and wineserver has given
//  the closed handle's value to a new object in between, the wait is on
//  something nobody signals, and the game hangs as it exits (Icy Tower:
//  about 3 exits in 11 on macOS 26). Kept open, the handle stays the
//  thread's, which a wait sees signalled. The cost is one handle per thread
//  `_beginthread` started, for the life of the process.
//
//  The change is to one instruction: `_endthread`'s `call [CloseHandle]`
//  becomes `pop ecx; test eax, <the same four bytes>`. The pop takes the
//  handle off the stack as CloseHandle (stdcall) would have; the test only
//  sets flags, which nothing reads, and keeps the call's address operand in
//  place, so the base relocation that covers it still lands on an operand
//  if the DLL is loaded somewhere else. The call is found by `_endthread`'s
//  export and the import slot of kernel32's CloseHandle, not by an offset,
//  and anything else there fails the step rather than patching blind.

import Foundation
import WindowsFormats
import WrappFormat
import WrappModuleKit

/// The patch to Wine's 32-bit msvcrt.dll that `WINE.PATCH keep-thread-handles`
/// makes in a tree's own copy of Wine (docs/modules.md#the-wine-modules-patches).
public nonisolated enum KeepThreadHandles {
    /// Part of the step's key: raise it whenever what the patch makes changes,
    /// so a layer an earlier one made isn't restored.
    public static let revision = 1

    public enum Outcome: Equatable, Sendable {
        case patched
        case alreadyPatched
    }

    public enum PatchError: Error, Equatable, CustomStringConvertible {
        case notPE32
        case exportMissing(String)
        case importMissing(String)
        case callNotFound
        case severalCalls(Int)
        case resultUsed(UInt8)

        public var description: String {
            switch self {
            case .notPE32: "msvcrt.dll isn't a 32-bit Windows DLL"
            case .exportMissing(let name): "msvcrt.dll exports no \(name)"
            case .importMissing(let name): "msvcrt.dll doesn't import \(name) from kernel32.dll"
            case .callNotFound: "msvcrt.dll's _endthread doesn't call CloseHandle; this Wine's isn't the one the patch knows"
            case .severalCalls(let count): "msvcrt.dll's _endthread calls CloseHandle \(count) times; this Wine's isn't the one the patch knows"
            case .resultUsed(let next):
                String(format: "msvcrt.dll's _endthread uses CloseHandle's result (the next byte is %02x, not a push); ", next)
                    + "this Wine's isn't the one the patch knows"
            }
        }
    }

    /// `call dword [imm32]`: an imported function called through its slot.
    static let callThroughSlot: [UInt8] = [0xff, 0x15]
    /// `pop ecx; test eax, imm32`: the handle off the stack, and the slot's
    /// address kept as an operand nothing reads.
    static let popAndTest: [UInt8] = [0x59, 0xa9]
    /// `push eax`: what Wine's GCC puts after a stdcall call whose result it
    /// doesn't need, putting back the stack space the callee popped.
    static let pushEAX: UInt8 = 0x50
    /// How far into `_endthread` the call is looked for, where no export
    /// after it says sooner where it ends.
    static let longestFunction = 0x200

    /// Returns `dll` with `_endthread` keeping the handle, or unchanged if it
    /// already does.
    public static func patch(_ dll: Data) throws -> (Data, Outcome) {
        guard let image = WindowsExecutable(data: dll), image.imageBase <= 0xffff_ffff else { throw PatchError.notPE32 }
        let exports = image.exports
        guard let entry = exports["_endthread"] else { throw PatchError.exportMissing("_endthread") }
        guard let slot = image.importSlot(of: "CloseHandle", from: "kernel32.dll") else {
            throw PatchError.importMissing("CloseHandle")
        }
        // The function runs to the next export at the latest.
        let end = exports.values.filter { $0 > entry }.min().map { min($0, entry + longestFunction) } ?? entry + longestFunction
        guard let start = image.fileOffset(ofRVA: entry), let last = image.fileOffset(ofRVA: end - 1),
              last - start == end - 1 - entry, last < dll.count else { throw PatchError.notPE32 }

        var bytes = [UInt8](dll)
        let address = littleEndian(image.imageBase + slot)
        func places(of opcode: [UInt8]) -> [Int] {
            let pattern = opcode + address
            return (start...(last + 1 - pattern.count)).filter { Array(bytes[$0..<$0 + pattern.count]) == pattern }
        }
        let calls = places(of: callThroughSlot)
        if calls.isEmpty, places(of: popAndTest).count == 1 { return (dll, .alreadyPatched) }
        guard let call = calls.first else { throw PatchError.callNotFound }
        guard calls.count == 1 else { throw PatchError.severalCalls(calls.count) }
        let next = call + 6 < bytes.count ? bytes[call + 6] : 0
        guard next == pushEAX else { throw PatchError.resultUsed(next) }

        bytes.replaceSubrange(call..<call + 2, with: popAndTest)
        return (Data(bytes), .patched)
    }

    /// `value` as four little-endian bytes.
    static func littleEndian(_ value: Int) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    /// Where a tree's Wine keeps its 32-bit msvcrt.dll, which the loader
    /// loads (a builtin, by its load order).
    public static func engineDLL(in tree: URL) -> URL {
        WrappLayout(app: tree).wine.appendingPathComponent("lib/wine/i386-windows/msvcrt.dll")
    }

    /// The prefix's copy of it, which wineboot lays in.
    public static func prefixDLL(in tree: URL) -> URL {
        WrappLayout(app: tree).driveC.appendingPathComponent("windows/syswow64/msvcrt.dll")
    }

    /// The tree's own Wine patched, and the prefix's copy of its msvcrt.dll
    /// with it, where that copy is Wine's (one someone installed is left
    /// alone). Each file is replaced, not written over, so the engine store
    /// it was cloned from is never touched. Returns what was done to the
    /// engine's.
    public static func apply(in tree: URL) throws -> Outcome {
        let engine = engineDLL(in: tree)
        guard FileManager.default.fileExists(atPath: engine.path) else {
            throw StepFailure.recipe("this tree has no Wine to patch (no \(engine.lastPathComponent) in its engine): WINE.PATCH goes after the stage has Wine")
        }
        let original = try Data(contentsOf: engine)
        let (patched, outcome) = try patch(original)
        if outcome == .patched { try patched.write(to: engine, options: .atomic) }

        let prefixCopy = prefixDLL(in: tree)
        if FileManager.default.fileExists(atPath: prefixCopy.path) {
            let copy = try Data(contentsOf: prefixCopy)
            if copy == original, copy != patched { try patched.write(to: prefixCopy, options: .atomic) }
        }
        return outcome
    }
}
