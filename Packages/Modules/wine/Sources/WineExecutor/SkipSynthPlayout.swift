//
//  SkipSynthPlayout.swift
//  WineExecutor
//
//  WINE.SKIP-SYNTH-PLAYOUT: Wine's 32-bit dmsynth.dll changed so that a
//  DirectMusic synthesiser's sink stops at once, rather than first playing
//  out what its sound buffer holds.
//
//  Wine 10's sink (dlls/dmsynth/synthsink.c) writes half a buffer of silence
//  when it's deactivated and then waits, in `synth_sink_wait_play_end`, until
//  everything written has played: a buffer is two seconds of sound, so each
//  stop takes about 1.5 s. Game Maker 7 games give each of their sounds a
//  DirectMusic performance of its own as they load, and stop each one's sink
//  again, so a game with 240 sounds sat on its loading screen for six
//  minutes (Iji). Wine 11.2 rewrote the sink to wait only for its write
//  latency, a few tens of milliseconds; this is the same, short of the wait.
//  Sound still playing in the buffer as it stops is cut off, which only a
//  sink stopped mid-note would notice, and the buffer is released (and so
//  stopped) straight afterwards anyway.
//
//  The change is to one instruction: the play-out loop's `jae <done>` (when
//  everything written has played) becomes `nop; jmp <done>`, the same
//  displacement in the same place, so the loop ends the first time round,
//  having written its silence and read the play position once. The loop is
//  found by its trace message ("Waiting for EOS, …"), which only it uses:
//  the `jae` is the one just before the check of whether that trace is on
//  (`test byte [<channel flags>], 8`), and its target must lie past the
//  message. Anything else there fails the step rather than patching blind.

import Foundation
import WindowsFormats
import WrappFormat
import WrappModuleKit

/// The patch to Wine's 32-bit dmsynth.dll that `WINE.SKIP-SYNTH-PLAYOUT`
/// makes in a tree's own copy of Wine (docs/modules.md#the-wine-modules-patches).
public nonisolated enum SkipSynthPlayout {
    /// Part of the step's key: raise it whenever what the patch makes changes,
    /// so a layer an earlier one made isn't restored.
    public static let revision = 1

    public enum Outcome: Equatable, Sendable {
        case patched
        case alreadyPatched
    }

    public enum PatchError: Error, Equatable, CustomStringConvertible {
        case notPE32
        case messageMissing
        case messageNotUsedOnce(Int)
        case loopTestNotFound
        case severalLoopTests(Int)
        case targetBeforeMessage

        public var description: String {
            switch self {
            case .notPE32: "dmsynth.dll isn't a 32-bit Windows DLL"
            case .messageMissing: "dmsynth.dll has no \"\(SkipSynthPlayout.message)\" message; this Wine's isn't the one the patch knows"
            case .messageNotUsedOnce(let count):
                "dmsynth.dll's play-out message is used \(count) times, not once; this Wine's isn't the one the patch knows"
            case .loopTestNotFound: "dmsynth.dll's play-out loop has no test the patch knows before its trace; this Wine's isn't the one the patch knows"
            case .severalLoopTests(let count):
                "dmsynth.dll's play-out loop has \(count) tests the patch could mean; this Wine's isn't the one the patch knows"
            case .targetBeforeMessage: "dmsynth.dll's play-out test doesn't jump out of the loop; this Wine's isn't the one the patch knows"
            }
        }
    }

    /// The start of the play-out loop's trace message, which nothing else prints.
    static let message = "Waiting for EOS, start_pos"
    /// `jae rel32`: out of the loop once everything written has played.
    static let jumpIfDone: [UInt8] = [0x0f, 0x83]
    /// `nop; jmp rel32`: out of the loop the first time round.
    static let jumpAlways: [UInt8] = [0x90, 0xe9]
    /// `test byte [abs32], 8`'s opcode and ModRM, before its address and the
    /// 8 (TRACE) that ends it: whether the loop's trace is on.
    static let traceCheck: [UInt8] = [0xf6, 0x05]
    static let traceBit: UInt8 = 0x08
    /// How far before the message's use the loop's test is looked for.
    static let window = 0x60

    /// Returns `dll` with the play-out loop ending at once, or unchanged if it
    /// already does.
    public static func patch(_ dll: Data) throws -> (Data, Outcome) {
        guard let image = WindowsExecutable(data: dll), image.imageBase <= 0xffff_ffff else { throw PatchError.notPE32 }
        var bytes = [UInt8](dll)

        // The message's address, as code that passes it holds it.
        let text = Array(message.utf8)
        guard let found = Self.offsets(of: text, in: bytes).first, let rva = image.rva(ofFileOffset: found) else {
            throw PatchError.messageMissing
        }
        let uses = Self.offsets(of: littleEndian(image.imageBase + rva), in: bytes)
        guard uses.count == 1, let use = uses.first else { throw PatchError.messageNotUsedOnce(uses.count) }

        // `jae`/`nop; jmp` rel32, then `test byte [abs32], 8`, before it.
        func tests(_ opcode: [UInt8]) -> [Int] {
            let first = max(0, use - window)
            return (first..<max(first, use - 12)).filter { at in
                Array(bytes[at..<at + 2]) == opcode && Array(bytes[at + 6..<at + 8]) == traceCheck && bytes[at + 12] == traceBit
            }
        }
        let unpatched = tests(jumpIfDone), patched = tests(jumpAlways)
        if unpatched.isEmpty, patched.count == 1 { return (dll, .alreadyPatched) }
        guard let test = unpatched.first else { throw PatchError.loopTestNotFound }
        guard unpatched.count == 1 else { throw PatchError.severalLoopTests(unpatched.count) }
        let displacement = Int(Int32(bitPattern: UInt32(bytes[test + 2]) | UInt32(bytes[test + 3]) << 8
            | UInt32(bytes[test + 4]) << 16 | UInt32(bytes[test + 5]) << 24))
        guard test + 6 + displacement > use else { throw PatchError.targetBeforeMessage }

        // The jmp's rel32 starts a byte later and ends where the jae's did,
        // so the displacement is the same.
        bytes.replaceSubrange(test..<test + 2, with: jumpAlways)
        return (Data(bytes), .patched)
    }

    /// Where `pattern` starts in `bytes`.
    static func offsets(of pattern: [UInt8], in bytes: [UInt8]) -> [Int] {
        guard let first = pattern.first, bytes.count >= pattern.count else { return [] }
        var found: [Int] = []
        var at = 0
        while at <= bytes.count - pattern.count {
            if bytes[at] == first, Array(bytes[at..<at + pattern.count]) == pattern { found.append(at) }
            at += 1
        }
        return found
    }

    /// `value` as four little-endian bytes.
    static func littleEndian(_ value: Int) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    /// Where a tree's Wine keeps its 32-bit dmsynth.dll, which the loader
    /// loads (a builtin, by its load order).
    public static func engineDLL(in tree: URL) -> URL {
        WrappLayout(app: tree).wine.appendingPathComponent("lib/wine/i386-windows/dmsynth.dll")
    }

    /// The prefix's copy of it, which wineboot lays in.
    public static func prefixDLL(in tree: URL) -> URL {
        WrappLayout(app: tree).driveC.appendingPathComponent("windows/syswow64/dmsynth.dll")
    }

    /// The tree's own Wine patched, and the prefix's copy of its dmsynth.dll
    /// with it, where that copy is Wine's (Microsoft's, which winetricks
    /// installs, is left alone). Each file is replaced, not written over, so
    /// the engine store it was cloned from is never touched. Returns what was
    /// done to the engine's.
    public static func apply(in tree: URL) throws -> Outcome {
        let engine = engineDLL(in: tree)
        guard FileManager.default.fileExists(atPath: engine.path) else {
            throw StepFailure.recipe("this tree has no Wine to patch (no \(engine.lastPathComponent) in its engine): WINE.SKIP-SYNTH-PLAYOUT goes after the stage has Wine")
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
