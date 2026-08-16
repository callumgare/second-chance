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
    /// trailing partial line at EOF — is forwarded to `logger` at `level`
    /// (stdout → `.notice`, stderr → `.error`, conventionally).
    ///
    /// Concurrency note: the captured `buffer` needs no lock — a
    /// `readabilityHandler` never runs concurrently with itself for the same
    /// `FileHandle`; each handle delivers on its own serial queue.
    ///
    /// Do NOT pair this with `waitForDataInBackgroundAndNotify` —
    /// `readabilityHandler` already schedules its own background reads.
    static func attach(to pipe: Pipe, logger: Logging.Logger, level: Logging.Logger.Level) {
        let fh = pipe.fileHandleForReading
        var buffer = Data()

        fh.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF — flush any trailing partial line.
                if !buffer.isEmpty {
                    let line = String(decoding: buffer, as: UTF8.self)
                        .trimmingCharacters(in: .newlines)
                    if !line.isEmpty {
                        logger.log(level: level, "\(line)")
                    }
                    buffer.removeAll()
                }
                handle.readabilityHandler = nil
                return
            }

            buffer.append(data)

            // Flush every complete line in the buffer.
            while let range = buffer.range(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                // String(decoding:as:) substitutes U+FFFD for invalid UTF-8
                // instead of returning nil (which would drop the whole line).
                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                if !line.isEmpty {
                    logger.log(level: level, "\(line)")
                }
            }
        }
    }
}
