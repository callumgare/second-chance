//
//  ReportBundle.swift
//  Shared
//
//  The zip a detailed failure report carries: this run's log and, for a
//  wrapp's failed start, its diagnostics bundle — every file redacted, and
//  the whole kept under `sizeCap`, Sentry's per-request limit being 40 MB
//  compressed. Over the cap, the thread samples go first (the biggest and
//  least often needed), then the log loses its oldest lines.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Reporting")

nonisolated enum ReportBundle {

    static let defaultSizeCap = 15 * 1024 * 1024

    enum Failure: Error {
        case zipFailed(status: Int32)
    }

    /// Build the zip in `directory` and return it.
    ///
    /// - Parameters:
    ///   - log: The run's log, unredacted.
    ///   - diagnostics: A diagnostics bundle to include, if there is one.
    static func make(log: String, diagnostics: URL?, redactor: ReportRedactor,
                     in directory: URL, sizeCap: Int = defaultSizeCap) throws -> URL {
        let staging = directory.appendingPathComponent("failure-report", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let logFile = staging.appendingPathComponent("log.txt")
        var logText = redactor.redact(log)
        try Data(logText.utf8).write(to: logFile)

        if let diagnostics {
            let copy = staging.appendingPathComponent("diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: diagnostics, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                do {
                    try redactor.redactFile(at: file, to: copy.appendingPathComponent(file.lastPathComponent))
                } catch {
                    logger.warning("Left \(file.lastPathComponent) out of the failure report: \(error.localizedDescription)")
                }
            }
        }

        let zip = directory.appendingPathComponent("failure-report.zip")
        try compress(staging, to: zip)
        if size(of: zip) > sizeCap {
            for sample in samples(in: staging) {
                try? FileManager.default.removeItem(at: sample)
            }
            try compress(staging, to: zip)
        }
        // Then the log's oldest half, until it fits or there's little left.
        while size(of: zip) > sizeCap, logText.utf8.count > 64 * 1024 {
            logText = "[earlier lines left out to fit the report]\n" + String(logText.suffix(logText.count / 2))
            try Data(logText.utf8).write(to: logFile)
            try compress(staging, to: zip)
        }
        logger.debug("Failure report bundle is \(size(of: zip)) bytes")
        return zip
    }

    /// The thread samples in a diagnostics bundle copy.
    static func samples(in staging: URL) -> [URL] {
        let copy = staging.appendingPathComponent("diagnostics", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: copy, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("sample") }
    }

    static func size(of file: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func compress(_ directory: URL, to zip: URL) throws {
        try? FileManager.default.removeItem(at: zip)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", directory.path, zip.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.zipFailed(status: process.terminationStatus) }
    }
}
