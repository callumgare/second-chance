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

/// Which stage of the run the log is in, so a summary can look back to
/// where the failing stage began.
///
/// A wrapp build binds a `BuildLogContext` for its whole run (`$build`), so
/// its entries carry its id and its own stage even while another build in
/// the same process (the integration tests run them side by side) is in a
/// different one. Outside a build there is just the process's stage.
nonisolated enum LogContext {
    private static let lock = NSLock()
    private static var _stage: String?
    private static var _stageStart: UInt64 = 0

    /// The build the current task is working for, if any. Work that leaves
    /// the task — a detached task, a dispatch queue, a pipe's reader — loses
    /// it unless it is carried across (`Blocking.run` and
    /// `ProcessLineLogger` do).
    @TaskLocal static var build: BuildLogContext?

    /// Mark the start of a stage. Repeating the current stage keeps its start.
    static func enterStage(_ name: String) {
        let start = LogStore.shared.nextSequence
        build?.enterStage(name, start: start)
        lock.withLock {
            guard _stage != name else { return }
            _stage = name
            _stageStart = start
        }
    }

    /// Leave the stage, at the start of a new run of work in the same
    /// process (another build), so a failure before its first stage isn't
    /// put in the last stage of the one before.
    static func clearStage() {
        let start = LogStore.shared.nextSequence
        build?.clearStage(start: start)
        lock.withLock {
            _stage = nil
            _stageStart = start
        }
    }

    /// The build's stage when there is one, else the process's.
    static var stage: (name: String?, start: UInt64) {
        if let build { return build.stage }
        return lock.withLock { (_stage, _stageStart) }
    }
}

/// One wrapp build's part of the log: an id its entries carry, and its stage.
nonisolated final class BuildLogContext: Sendable {
    let id: String
    private let state: Mutex<(stage: String?, start: UInt64)>

    init(id: String = String(UUID().uuidString.prefix(8)).lowercased()) {
        self.id = id
        state = Mutex((nil, LogStore.shared.nextSequence))
    }

    var stage: (name: String?, start: UInt64) {
        state.withLock { ($0.stage, $0.start) }
    }

    func enterStage(_ name: String, start: UInt64) {
        state.withLock {
            guard $0.stage != name else { return }
            $0 = (name, start)
        }
    }

    func clearStage(start: UInt64) {
        state.withLock { $0 = (nil, start) }
    }
}

/// An error, with the details `localizedDescription` drops: its type and
/// case, and the chain of underlying errors.
nonisolated enum ErrorChain {
    static func describe(_ error: Error) -> String {
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

    /// The error's type and case and nothing else — `WrappBuildError.installIncomplete`,
    /// `NSCocoaErrorDomain 513` — safe to send where a message is not, since
    /// messages and associated values can hold paths.
    static func identifier(_ error: Error) -> String {
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
    static func underlyingIdentifiers(_ error: Error) -> [String] {
        var result: [String] = []
        var next = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        while let underlying = next, result.count < 5 {
            result.append(identifier(underlying))
            next = (underlying as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        }
        return result
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
    /// - Returns: The summary, for a detailed failure report.
    @discardableResult
    static func log(_ logger: Logging.Logger, what: String, error: Error? = nil, files: [(String, String)] = []) -> String {
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

        // Debug lines are chatter by definition (msync start-up, fixme:).
        let engine = entries.filter { isEngineOutput($0) && $0.level != "debug" && $0.level != "trace" }.suffix(10)
        if !engine.isEmpty {
            lines.append("Last Wine/ScummVM output:")
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
