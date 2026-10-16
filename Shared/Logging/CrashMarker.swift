//
//  CrashMarker.swift
//  Shared
//
//  Leaves a trace when this process dies of a fatal signal, and reports the
//  previous run's crash at the next start. A Swift trap or an AppKit
//  assertion (SIGILL, SIGTRAP), or a SIGSEGV, ends the process before
//  anything in the log says why; the crash report macOS writes is in
//  ~/Library/Logs/DiagnosticReports, but nothing points at it.
//
//  The signal handler may only use async-signal-safe calls, so it never
//  touches LogStore or swift-log: it writes a prepared line to stderr and to
//  a marker file opened in advance, then re-raises the signal so the crash
//  report is still written.

import Foundation
import Logging

nonisolated enum CrashMarker {

    private static let fatalSignals: [Int32] = [SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGBUS, SIGSEGV]

    // Read by the signal handler, so plain C storage, filled before the
    // handler is installed and never changed after: a message per signal
    // number, and its length.
    private static let slots = 64
    nonisolated(unsafe) private static var markerFD: Int32 = -1
    nonisolated(unsafe) private static let messageTexts = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: slots)
    nonisolated(unsafe) private static let messageLengths = UnsafeMutablePointer<Int>.allocate(capacity: slots)

    /// Report a crash the previous run left in `directory`, then arm the
    /// handler for this run. Call once, early, after logging is bootstrapped.
    static func install(in directory: URL, logger: Logging.Logger) {
        let marker = directory.appendingPathComponent("crash-marker")
        reportPrevious(marker: marker, logger: logger)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.warning("Can't create \(directory.path) for the crash marker: \(error.localizedDescription)")
            return
        }
        markerFD = open(marker.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard markerFD >= 0 else {
            logger.warning("Can't open the crash marker \(marker.path)")
            return
        }

        let process = ProcessInfo.processInfo.processName
        messageTexts.initialize(repeating: nil, count: slots)
        messageLengths.initialize(repeating: 0, count: slots)
        for sig in fatalSignals {
            let text = "\n💥 \(process) (pid \(getpid())) crashed: \(SubprocessWatch.signalName(sig)), run \(RunContext.runID), at unix time \(Int(Date().timeIntervalSince1970)) or later\n"
            guard sig < slots, let pointer = strdup(text) else { continue }
            messageTexts[Int(sig)] = pointer
            messageLengths[Int(sig)] = strlen(pointer)

            var action = sigaction()
            action.__sigaction_u.__sa_handler = CrashMarker.handle
            action.sa_flags = SA_RESETHAND
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
    }

    /// The handler: async-signal-safe calls only.
    private static let handle: @convention(c) (Int32) -> Void = { sig in
        if sig >= 0, sig < CrashMarker.slots, let pointer = CrashMarker.messageTexts[Int(sig)] {
            let length = CrashMarker.messageLengths[Int(sig)]
            _ = write(STDERR_FILENO, pointer, length)
            if CrashMarker.markerFD >= 0 {
                _ = write(CrashMarker.markerFD, pointer, length)
            }
        }
        // SA_RESETHAND restored the default action: die as we would have,
        // so macOS still writes its crash report.
        raise(sig)
    }

    private static func reportPrevious(marker: URL, logger: Logging.Logger) {
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let modified = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        var message = "The previous run crashed: \(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "💥 ", with: ""))"
        if let report = crashReport(after: modified?.addingTimeInterval(-60)) {
            message += "\n  Crash report: \(report.path)"
        }
        logger.error("\(message)")
    }

    /// The newest crash report for this process written after `date`.
    static func crashReport(after date: Date?) -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let prefix = ProcessInfo.processInfo.processName + "-"
        let reports = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []).filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "ips" }
        let dated = reports.compactMap { url -> (URL, Date)? in
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (url, modified)
        }
        return dated
            .filter { report in date.map { report.1 >= $0 } ?? true }
            .max { $0.1 < $1.1 }?.0
    }
}
