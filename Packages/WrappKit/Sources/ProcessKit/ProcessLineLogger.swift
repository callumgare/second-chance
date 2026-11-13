//
//  ProcessLineLogger.swift
//  ProcessKit
//
//  Line-buffering reader for a Process pipe. Forwards each complete line to
//  a logger at the given level. Handles lines split across read chunks and
//  multi-byte UTF-8 sequences split mid-chunk (replaced rather than dropped).

import Foundation
import Logging
import WrappLogging

nonisolated public enum ProcessLineLogger {

    /// Attach a line-buffering reader to a pipe. Each complete line — and any
    /// trailing partial line at EOF — is forwarded to `logger`, at the level
    /// `SubprocessLineClassifier` picks from the line's content, falling back
    /// to `level` (stdout → `.notice`, stderr → `.warning`, conventionally).
    /// Pass `classify: false` to log every line at exactly `level`, or
    /// `levelFor` to choose each line's level yourself. `metadata` goes on
    /// every line (a subprocess's pid, say).
    ///
    /// Concurrency note: the captured `buffer` needs no lock — a
    /// `readabilityHandler` never runs concurrently with itself for the same
    /// `FileHandle`; each handle delivers on its own serial queue.
    ///
    /// Do NOT pair this with `waitForDataInBackgroundAndNotify` —
    /// `readabilityHandler` already schedules its own background reads.
    ///
    /// `onLine`, when given, also receives each line — on the pipe's reader
    /// queue, so it must be quick and thread-safe. `onEOF`, when given, is
    /// called once the pipe reaches end-of-file and the last line is logged.
    public static func attach(
        to pipe: Pipe,
        logger: Logging.Logger,
        level: Logging.Logger.Level,
        classify: Bool = true,
        levelFor: (@Sendable (String) -> Logging.Logger.Level)? = nil,
        metadata: Logging.Logger.Metadata? = nil,
        onLine: (@Sendable (String) -> Void)? = nil,
        onEOF: (@Sendable () -> Void)? = nil
    ) {
        let levelOf: @Sendable (String) -> Logging.Logger.Level
        if let levelFor {
            levelOf = levelFor
        } else if classify {
            levelOf = { SubprocessLineClassifier.level(for: $0, fallback: level) }
        } else {
            levelOf = { _ in level }
        }
        let fh = pipe.fileHandleForReading
        let pending = PendingBytes()
        // The pipe is read on a queue of its own, outside the task that
        // started the program, so carry its build across to each line.
        let build = LogContext.build

        fh.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF — flush any trailing partial line.
                if !pending.buffer.isEmpty {
                    let line = String(decoding: pending.buffer, as: UTF8.self)
                        .trimmingCharacters(in: .newlines)
                    if !line.isEmpty {
                        LogContext.$build.withValue(build) { pending.log(line, logger: logger, level: levelOf, metadata: metadata) }
                        onLine?(line)
                    }
                    pending.buffer.removeAll()
                }
                LogContext.$build.withValue(build) { pending.endRepeats(logger: logger, metadata: metadata) }
                handle.readabilityHandler = nil
                onEOF?()
                return
            }

            pending.buffer.append(data)

            // Every complete line in one pass, then the consumed bytes
            // removed once: searching from the start and removing each line
            // in turn made a chatty program's (WINEDEBUG=+relay) reads
            // quadratic. A lone carriage return ends a line too, as a
            // progress line rewritten in place would otherwise grow for good.
            var lineStart = pending.buffer.startIndex
            var lines: [String] = []
            for index in pending.buffer.indices where pending.buffer[index] == 0x0A || pending.buffer[index] == 0x0D {
                lines.append(Self.line(pending.buffer[lineStart..<index]))
                lineStart = pending.buffer.index(after: index)
            }
            // A line with no end in sight is let out in pieces rather than
            // held without limit (the log keeps 16 KB of an entry anyway).
            if pending.buffer.endIndex - lineStart > Self.maxLineBytes {
                lines.append(Self.line(pending.buffer[lineStart...]))
                lineStart = pending.buffer.endIndex
            }
            if lineStart > pending.buffer.startIndex {
                pending.buffer.removeSubrange(pending.buffer.startIndex..<lineStart)
            }
            for line in lines where !line.isEmpty {
                LogContext.$build.withValue(build) { pending.log(line, logger: logger, level: levelOf, metadata: metadata) }
                onLine?(line)
            }
        }
    }

    /// The most of an unfinished line held before it is let out as it is.
    static let maxLineBytes = 64 * 1024

    /// `bytes` as a line of text. String(decoding:as:) substitutes U+FFFD
    /// for invalid UTF-8 instead of returning nil (which would drop the
    /// whole line).
    private static func line(_ bytes: Data) -> String {
        String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// How many copies of a line repeated back to back are logged before the
    /// rest are only counted. A Wine process that lost its wineserver logged
    /// the same msync error four million times in two minutes, pushing the
    /// whole build out of the log (Ghost of Thornton Hall, 2026-11-13).
    static let repeatsLogged = 3
    /// While a line goes on repeating, how often the count so far is logged.
    static let repeatsSummaryEvery = 100_000

    /// The bytes of a line still being read, and the line last logged with
    /// how often it has repeated since. Only the pipe's readability handler
    /// touches it, and a file handle runs that handler one read at a time,
    /// so it needs no lock.
    nonisolated final class PendingBytes: @unchecked Sendable {
        var buffer = Data()
        private var lastLine: String?
        private var lastLevel: Logging.Logger.Level = .notice
        /// Copies of `lastLine` since it was first logged.
        private var repeats = 0
        /// Of those, how many haven't been counted in the log yet.
        private var uncounted = 0

        /// Log `line`, unless it's the line before repeated more than
        /// `repeatsLogged` times, when it's counted instead.
        func log(_ line: String, logger: Logging.Logger, level levelOf: (String) -> Logging.Logger.Level,
                 metadata: Logging.Logger.Metadata?) {
            if line == lastLine {
                repeats += 1
                if repeats < ProcessLineLogger.repeatsLogged {
                    logger.log(level: lastLevel, "\(line)", metadata: metadata)
                    return
                }
                uncounted += 1
                if uncounted >= ProcessLineLogger.repeatsSummaryEvery {
                    logger.log(level: lastLevel, "(the line above repeated \(uncounted) more times, and goes on repeating)", metadata: metadata)
                    uncounted = 0
                }
                return
            }
            endRepeats(logger: logger, metadata: metadata)
            lastLine = line
            lastLevel = levelOf(line)
            repeats = 0
            logger.log(level: lastLevel, "\(line)", metadata: metadata)
        }

        /// Log how often the last line repeated, if it did so uncounted.
        func endRepeats(logger: Logging.Logger, metadata: Logging.Logger.Metadata?) {
            if uncounted > 0 {
                logger.log(level: lastLevel, "(the line above repeated \(uncounted) more times)", metadata: metadata)
            }
            uncounted = 0
        }
    }
}
