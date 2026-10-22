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
//  a marker file opened in advance, then puts back the handler that was
//  there before it and re-raises, so the crash report is still written.

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
    /// The action each signal had before ours, to hand the crash on to.
    nonisolated(unsafe) private static let previousActions = UnsafeMutablePointer<sigaction>.allocate(capacity: slots)

    private static var armed = false

    /// Install the handler — unless Sentry is handling crashes in this run
    /// (`FailureReporter.handlesCrashes`). Sentry takes a real crash first,
    /// through a Mach exception handler, then puts back the signal handlers
    /// that were there before it, so ours would only ever see a fatal signal
    /// sent with `kill` (docs/failure-reports.md#crash-handlers). Sentry
    /// records the crash then, and says so at the next start. Call after
    /// `FailureReporter.start`. Until `install(in:)` names the marker file, a
    /// crash is written to stderr only.
    static func arm() {
        guard !armed else { return }
        armed = true
        guard !FailureReporter.handlesCrashes else { return }
        let process = ProcessInfo.processInfo.processName
        messageTexts.initialize(repeating: nil, count: slots)
        messageLengths.initialize(repeating: 0, count: slots)
        previousActions.initialize(repeating: sigaction(), count: slots)
        for sig in fatalSignals {
            let signalName = SubprocessWatch.signalName(sig)
            let text = "\n💥 \(process) (pid \(getpid())) crashed: \(signalName), run \(RunContext.runID), "
                + "at unix time \(Int(Date().timeIntervalSince1970)) or later\n"
            guard sig < slots, let pointer = strdup(text) else { continue }
            messageTexts[Int(sig)] = pointer
            messageLengths[Int(sig)] = strlen(pointer)

            var action = sigaction()
            action.__sigaction_u.__sa_handler = CrashMarker.handle
            action.sa_flags = SA_RESETHAND
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, previousActions + Int(sig))
        }
    }

    /// Report a crash the previous run left in `directory`, and keep this
    /// run's marker there. Arms the handler too, if `arm()` hasn't.
    static func install(in directory: URL, logger: Logging.Logger) {
        arm()
        let marker = directory.appendingPathComponent("crash-marker")
        reportPrevious(marker: marker, logger: logger)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.warning("Can't create \(directory.path) for the crash marker: \(error.localizedDescription)")
            return
        }
        markerFD = open(marker.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if markerFD < 0 {
            logger.warning("Can't open the crash marker \(marker.path)")
        }
    }

    /// The handler: async-signal-safe calls only.
    private static let handle: @convention(c) (Int32) -> Void = { sig in
        // Put the previous action back by hand: macOS ignores SA_RESETHAND
        // for SIGILL and SIGTRAP, and a handler that re-raises those without
        // this runs again, for ever.
        if sig >= 0, sig < CrashMarker.slots {
            sigaction(sig, CrashMarker.previousActions + Int(sig), nil)
        } else {
            var defaultAction = sigaction()
            defaultAction.__sigaction_u.__sa_handler = SIG_DFL
            sigemptyset(&defaultAction.sa_mask)
            sigaction(sig, &defaultAction, nil)
        }

        if sig >= 0, sig < CrashMarker.slots, let pointer = CrashMarker.messageTexts[Int(sig)] {
            let length = CrashMarker.messageLengths[Int(sig)]
            _ = write(STDERR_FILENO, pointer, length)
            if CrashMarker.markerFD >= 0 {
                _ = write(CrashMarker.markerFD, pointer, length)
            }
        }
        // Die as we would have, so macOS still writes its crash report.
        raise(sig)
    }

    private static func reportPrevious(marker: URL, logger: Logging.Logger) {
        // Only the start: the marker holds one line per crash.
        guard let handle = try? FileHandle(forReadingFrom: marker) else { return }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        try? handle.close()
        let text = String(decoding: head, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
