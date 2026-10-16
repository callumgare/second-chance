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

/// Which stage of the run the log is in, so a summary can look back to
/// where the failing stage began.
nonisolated enum LogContext {
    private static let lock = NSLock()
    private static var _stage: String?
    private static var _stageStart: UInt64 = 0

    /// Mark the start of a stage. Repeating the current stage keeps its start.
    static func enterStage(_ name: String) {
        let start = LogStore.shared.nextSequence
        lock.withLock {
            guard _stage != name else { return }
            _stage = name
            _stageStart = start
        }
    }

    static var stage: (name: String?, start: UInt64) {
        lock.withLock { (_stage, _stageStart) }
    }
}

/// An error, with the details `localizedDescription` drops: its type and
/// case, and the chain of underlying errors.
nonisolated enum ErrorChain {
    static func describe(_ error: Error) -> String {
        // The type and case, without the associated values, which usually
        // repeat the message.
        let reflected = String(reflecting: error)
        let kind = reflected.split(separator: "(", maxSplits: 1).first.map(String.init) ?? reflected
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
}

nonisolated enum FailureSummary {

    static let startMarker = "=== FAILURE SUMMARY ==="
    static let endMarker = "=== END FAILURE SUMMARY ==="

    /// Log the summary as one critical entry.
    ///
    /// - Parameters:
    ///   - what: What failed, e.g. "Building Secrets Can Kill".
    ///   - error: The error it failed with, if there is one.
    ///   - files: Other evidence worth naming: a diagnostics bundle, a crash report.
    static func log(_ logger: Logging.Logger, what: String, error: Error? = nil, files: [(String, String)] = []) {
        logger.critical("\(render(what: what, error: error, files: files))")
        LogStore.shared.flush()
    }

    static func render(what: String, error: Error?, files: [(String, String)] = []) -> String {
        let (stage, stageStart) = LogContext.stage
        let entries = LogStore.shared.snapshot().entries

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

        let engine = entries.filter { isEngineOutput($0) }.suffix(10)
        if !engine.isEmpty {
            lines.append("Last Wine/ScummVM output:")
            lines += engine.map { "  \(oneLine($0))" }
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

    /// Lines Wine, a Windows program or ScummVM printed, rather than ours
    /// about them: the `Wine` and `ScummVM` categories.
    private static func isEngineOutput(_ entry: Entry) -> Bool {
        entry.label.hasSuffix(".Wine") || entry.label.hasSuffix(".ScummVM")
    }

    private static func oneLine(_ entry: Entry) -> String {
        let time = LogFormatter.time(entry: entry)
        let category = entry.label.split(separator: ".").last.map(String.init) ?? entry.label
        let message = entry.message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return "\(time)  \(entry.level)  \(category)  \(message)"
    }
}
