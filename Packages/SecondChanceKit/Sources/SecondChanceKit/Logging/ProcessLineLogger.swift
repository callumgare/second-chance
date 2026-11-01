//
//  ProcessLineLogger.swift
//  Shared
//
//  Line-buffering reader for a Process pipe. Forwards each complete line to
//  a logger at the given level. Handles lines split across read chunks and
//  multi-byte UTF-8 sequences split mid-chunk (replaced rather than dropped).

import Foundation
import Logging

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
                        LogContext.$build.withValue(build) { logger.log(level: levelOf(line), "\(line)", metadata: metadata) }
                        onLine?(line)
                    }
                    pending.buffer.removeAll()
                }
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
                LogContext.$build.withValue(build) { logger.log(level: levelOf(line), "\(line)", metadata: metadata) }
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

    /// The bytes of a line still being read. Only the pipe's readability
    /// handler touches it, and a file handle runs that handler one read at a
    /// time, so it needs no lock.
    private nonisolated final class PendingBytes: @unchecked Sendable {
        var buffer = Data()
    }
}
