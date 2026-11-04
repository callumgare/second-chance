//
//  HelperReportFile.swift
//  SecondChanceKit
//
//  The in-process helpers' report lines from a file, for a game Wine starts
//  with no output of the wrapp's to write them to: an owned Big Fish game,
//  which Big Fish's DRM service starts. The helpers append each line to the
//  file `SECOND_CHANCE_HELPER_REPORTS` names, as well as to stderr
//  (`helper_common.h`), and this hands each whole line on as it comes, as a
//  program's output is.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.HelperReportFile")

public nonisolated final class HelperReportFile: @unchecked Sendable {
    /// The variable that names the file to the helpers.
    public static let variable = "SECOND_CHANCE_HELPER_REPORTS"

    public let url: URL
    private let queue = DispatchQueue(label: "au.gare.callum.second-chance.HelperReportFile")
    private var timer: DispatchSourceTimer?
    // On `queue`.
    private var offset: UInt64 = 0
    private var partial = Data()

    /// This launch's own file, in `directory`: what `variable` names.
    public static func url(in directory: URL = FileManager.default.temporaryDirectory) -> URL {
        directory.appendingPathComponent("second-chance-helper-reports-\(getpid()).log")
    }

    /// Read `url`, from what is written to it from now on.
    public init(url: URL) {
        self.url = url
        try? FileManager.default.removeItem(at: url)
    }

    /// Look for new lines four times a second, handing each to `onLine`, on
    /// a queue of the file's own.
    public func start(onLine: @escaping @Sendable (String) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.read(onLine: onLine) }
        self.timer = timer
        timer.resume()
    }

    /// Stop looking, and remove the file.
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch {
            logger.warning("Couldn't remove \(url.path): \(error)")
        }
    }

    private func read(onLine: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return }
            offset += UInt64(data.count)
            partial.append(data)
        } catch {
            return
        }
        for line in Self.takeLines(from: &partial) { onLine(line) }
    }

    /// The whole lines at the start of `buffer`, taken out of it; a line
    /// still being written stays.
    static func takeLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}
