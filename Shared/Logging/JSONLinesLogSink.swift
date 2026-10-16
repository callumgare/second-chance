//
//  JSONLinesLogSink.swift
//  Shared
//
//  The log as one JSON object per line, for programs and agents: filter by
//  level, category, stage or a subprocess's pid with `jq` instead of
//  parsing the text format's columns, emoji and bracketed prefixes.
//
//    {"category":"Wine","label":"au.gare.callum.second-chance.Shared.Wine",
//     "level":"error","message":"0124:err:module:import_dll …",
//     "metadata":{"pid":"1237","program":"wine setup.exe"},"pid":4120,
//     "process":"Second Chance","run":"3f9a2c1e","seq":812,
//     "stage":"Game installing","time":"2026-10-16T06:22:45.627Z"}
//
//  Turned on by SECOND_CHANCE_LOG_JSONL=<path>; sc sets it for wrapp builds.

import Foundation

nonisolated final class JSONLinesLogSink: @unchecked Sendable {

    private let handle: FileHandle
    private var cancel: (@Sendable () -> Void)?
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Kept alive for the life of the process once started.
    nonisolated(unsafe) private static var shared: JSONLinesLogSink?

    /// Start writing every entry, from the start of the process, to `path`.
    static func start(path: URL) {
        guard shared == nil else { return }
        FileManager.default.createFile(atPath: path.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path.path) else { return }
        let sink = JSONLinesLogSink(handle: handle)
        shared = sink
        let (snapshot, cancel) = LogStore.shared.subscribe { batch in sink.write(batch) }
        sink.cancel = cancel
        sink.write(snapshot)
    }

    private init(handle: FileHandle) {
        self.handle = handle
    }

    private func write(_ entries: [Entry]) {
        let lines = entries.compactMap(Self.encode).joined()
        guard !lines.isEmpty else { return }
        // Throwing variant: the plain one raises on a full disk.
        try? handle.write(contentsOf: Data(lines.utf8))
    }

    /// One entry as a JSON line, newline included.
    static func encode(_ entry: Entry) -> String? {
        var object: [String: Any] = [
            "time": formatter.string(from: entry.timestamp),
            "seq": entry.seq,
            "level": entry.level,
            "label": entry.label,
            "category": entry.label.split(separator: ".").last.map(String.init) ?? entry.label,
            "message": entry.message,
            "run": RunContext.runID,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "process": ProcessInfo.processInfo.processName,
        ]
        if let error = entry.error { object["error"] = error }
        if let stage = entry.stage { object["stage"] = stage }
        if !entry.metadata.isEmpty { object["metadata"] = entry.metadata }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
