//
//  RotatingLogFile.swift
//  Shared
//
//  A log file per launch, in a folder that keeps the newest few — so a
//  wrapp started from Finder, which has no terminal, still leaves a log
//  behind when it fails.

import Foundation
import Logging

nonisolated enum RotatingLogFile {

    /// Start mirroring the whole log (every level, from the start of the
    /// process) to a new `<prefix>-<time>.log` in `directory`, removing all
    /// but the newest `keep` files there. Does nothing when the caller chose
    /// a file already (`SECOND_CHANCE_LOG_FILE`, `--mirror-logs`). Returns
    /// the file in use.
    @discardableResult
    static func start(in directory: URL, prefix: String, keep: Int = 10, logger: Logging.Logger) -> URL? {
        if let chosen = LogStore.shared.diskMirrorPath {
            return chosen
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.warning("Can't create the log folder \(directory.path): \(error.localizedDescription); this launch keeps no log file")
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let file = directory.appendingPathComponent("\(prefix)-\(formatter.string(from: Date())).log")
        LogStore.shared.setDiskMirror(enabled: true, path: file)
        prune(directory, prefix: prefix, keep: keep, logger: logger)
        return file
    }

    private static func prune(_ directory: URL, prefix: String, keep: Int, logger: Logging.Logger) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        // The timestamp in the name sorts chronologically.
        let logs = files
            .filter { $0.lastPathComponent.hasPrefix("\(prefix)-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in logs.dropFirst(keep) {
            do {
                try FileManager.default.removeItem(at: old)
            } catch {
                logger.warning("Can't remove old log \(old.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
