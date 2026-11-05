//
//  FailureSummary.swift
//  Shared
//
//  The block a failed run ends with: what failed, the whole error, the first
//  error line of the stage it failed in, the last thing Wine said, and where
//  the other evidence is. The cause of a failure is usually logged well
//  before the failure itself — an installer's err: line minutes before the
//  "exited 1" — and this puts the two side by side at the bottom, where both
//  a person and `grep -A30 'FAILURE SUMMARY'` look first.

import Foundation
import Logging
import Synchronization

/// An error, with the details `localizedDescription` drops: its type and
/// case, and the chain of underlying errors.
nonisolated public enum ErrorChain {
    public static func describe(_ error: Error) -> String {
        // The type and case, without the associated values, which usually
        // repeat the message.
        let reflected = String(reflecting: error)
        let ns = error as NSError
        let kind = reflected.hasPrefix("Error Domain=")
            ? "\(ns.domain) \(ns.code)"
            : reflected.split(separator: "(", maxSplits: 1).first.map(String.init) ?? reflected
        var parts = ["\(error.localizedDescription) [\(kind)]"]
        var next = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        var depth = 0
        while let underlying = next, depth < 5 {
            let ns = underlying as NSError
            parts.append("caused by: \(underlying.localizedDescription) [\(ns.domain) \(ns.code)]")
            next = ns.userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return parts.joined(separator: "\n  ")
    }

    /// Whether `error`, or one it was caused by, is the disk being full:
    /// Foundation's out-of-space error or POSIX's `ENOSPC`.
    public static func isOutOfSpace(_ error: Error) -> Bool {
        var next: Error? = error
        var depth = 0
        while let current = next, depth < 6 {
            let ns = current as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
            if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
            next = ns.userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return false
    }

    /// The error's type and case and nothing else — `WrappBuildError.installIncomplete`,
    /// `NSCocoaErrorDomain 513` — safe to send where a message is not, since
    /// messages and associated values can hold paths.
    public static func identifier(_ error: Error) -> String {
        if type(of: error) is NSError.Type {
            let ns = error as NSError
            return "\(ns.domain) \(ns.code)"
        }
        let typeName = qualifiedName(of: type(of: error))
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else { return typeName }
        // A case with associated values reflects as one child labelled with
        // the case; a case without them describes as its name.
        if let label = mirror.children.first?.label {
            return "\(typeName).\(label)"
        }
        let name = String(describing: error)
        return name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) ? "\(typeName).\(name)" : typeName
    }

    /// The type's name with what it is nested in (`WrappSteam.Failure`, not
    /// `Failure`), but not its module, which differs between the app and the
    /// wrapp for the same Shared type.
    private static func qualifiedName(of type: Any.Type) -> String {
        let parts = String(reflecting: type).split(separator: ".").dropFirst()
            // A private type's context reads "(unknown context at $…)".
            .filter { !$0.contains("(") && !$0.contains(" ") && !$0.contains("$") }
        return parts.isEmpty ? String(describing: type) : parts.joined(separator: ".")
    }

    /// `identifier` for each error the chain names as an underlying cause.
    public static func underlyingIdentifiers(_ error: Error) -> [String] {
        var result: [String] = []
        var next = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        while let underlying = next, result.count < 5 {
            result.append(identifier(underlying))
            next = (underlying as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        }
        return result
    }
}

nonisolated public enum FailureSummary {

    static let startMarker = "=== FAILURE SUMMARY ==="
    static let endMarker = "=== END FAILURE SUMMARY ==="

    /// Log the summary as one critical entry.
    ///
    /// - Parameters:
    ///   - what: What failed, e.g. "Building Secrets Can Kill".
    ///   - error: The error it failed with, if there is one.
    ///   - files: Other evidence worth naming: a diagnostics bundle, a crash report.
    /// - Returns: The summary, for a detailed failure report.
    @discardableResult
    public static func log(_ logger: Logging.Logger, what: String, error: Error? = nil, files: [(String, String)] = []) -> String {
        let summary = render(what: what, error: error, files: files)
        logger.critical("\(summary)")
        LogStore.shared.flush()
        return summary
    }

    static func render(what: String, error: Error?, files: [(String, String)] = []) -> String {
        let (stage, stageStart) = LogContext.stage
        // Only this build's, when another may be running alongside it.
        let build = LogContext.build?.id
        let entries = LogStore.shared.snapshot().entries.filter { build == nil || $0.build == build }

        var lines = [startMarker, "What failed: \(what)\(stage.map { ", during \"\($0)\"" } ?? "")"]
        if let error {
            lines.append("Error: \(ErrorChain.describe(error))")
        }

        // The first error the failing stage logged is usually the cause; the
        // last ones are usually its consequences.
        let stageEntries = entries.filter { $0.seq >= stageStart }
        if let first = stageEntries.first(where: { isError($0) }) {
            lines.append("First error in this stage: \(oneLine(first))")
        }

        // What the stage had running beside the step that failed: a Wine
        // program started alongside a disc's copy was what broke it once,
        // and the failure itself said nothing of it.
        let programs = stageEntries.filter { $0.label.hasSuffix(".WineProcess") && ($0.message.hasPrefix("▶ ") || $0.message.hasPrefix("■ ")) }
        if !programs.isEmpty {
            lines.append("Programs this stage started and ended:")
            lines += programs.suffix(8).map { "  \(oneLine($0))" }
        }

        // Debug lines are chatter by definition (msync start-up, fixme:).
        let engine = entries.filter { isEngineOutput($0) && $0.level != "debug" && $0.level != "trace" }.suffix(10)
        if !engine.isEmpty {
            lines.append("Last Wine, ScummVM or DOSBox output:")
            lines += engine.map { "  \(oneLine($0))" }
        }

        // A busy Mac is the likeliest cause of a Wine program failing to
        // start, and the load may have passed by the time it is noticed.
        lines.append("Load now: \(SystemLoad.read().map(\.summary) ?? "unknown (ps failed)")")
        if let recent = SystemLoadHistory.shared.summary() {
            lines.append("Load recently: \(recent)")
        }

        var evidence = files
        if let mirror = LogStore.shared.diskMirrorPath {
            evidence.insert(("Full log", mirror.path), at: 0)
        }
        evidence.append(("Run", RunContext.runID))
        lines += evidence.map { "\($0.0): \($0.1)" }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    private static func isError(_ entry: Entry) -> Bool {
        entry.level == "error" || entry.level == "critical"
    }

    /// Lines Wine, a Windows program, ScummVM or DOSBox printed, rather
    /// than ours about them: the `Wine`, `ScummVM` and `DOSBox` categories.
    private static func isEngineOutput(_ entry: Entry) -> Bool {
        entry.label.hasSuffix(".Wine") || entry.label.hasSuffix(".ScummVM") || entry.label.hasSuffix(".DOSBox")
    }

    private static func oneLine(_ entry: Entry) -> String {
        let time = LogFormatter.time(entry: entry)
        let category = entry.label.split(separator: ".").last.map(String.init) ?? entry.label
        let message = entry.message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return "\(time)  \(entry.level)  \(category)  \(message)"
    }
}
