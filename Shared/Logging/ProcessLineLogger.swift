//
//  ProcessLineLogger.swift
//  Shared
//
//  Line-buffering reader for a Process pipe. Forwards each complete line to
//  a logger at the given level. Handles lines split across read chunks and
//  multi-byte UTF-8 sequences split mid-chunk (replaced rather than dropped).

import Foundation
import Logging

nonisolated enum ProcessLineLogger {

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
    static func attach(
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

        fh.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF — flush any trailing partial line.
                if !pending.buffer.isEmpty {
                    let line = String(decoding: pending.buffer, as: UTF8.self)
                        .trimmingCharacters(in: .newlines)
                    if !line.isEmpty {
                        logger.log(level: levelOf(line), "\(line)", metadata: metadata)
                        onLine?(line)
                    }
                    pending.buffer.removeAll()
                }
                handle.readabilityHandler = nil
                onEOF?()
                return
            }

            pending.buffer.append(data)

            // Flush every complete line in the buffer.
            while let range = pending.buffer.range(of: Data([0x0A])) {
                let lineData = pending.buffer.subdata(in: pending.buffer.startIndex..<range.lowerBound)
                pending.buffer.removeSubrange(pending.buffer.startIndex..<range.upperBound)
                // String(decoding:as:) substitutes U+FFFD for invalid UTF-8
                // instead of returning nil (which would drop the whole line).
                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                if !line.isEmpty {
                    logger.log(level: levelOf(line), "\(line)", metadata: metadata)
                    onLine?(line)
                }
            }
        }
    }

    /// The bytes of a line still being read. Only the pipe's readability
    /// handler touches it, and a file handle runs that handler one read at a
    /// time, so it needs no lock.
    private nonisolated final class PendingBytes: @unchecked Sendable {
        var buffer = Data()
    }
}
