//
//  RecordingEvents.swift
//  WrappPuppeteer
//
//  What happened during a run, marked in its screen recording: this
//  run's steps, from its own log, and the wrapp's, from its launch log, each
//  at the moment it happened in the video (VideoAnnotator).

import Foundation
import Logging
import PuppeteerCore
import SecondChanceKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.RecordingEvents")

nonisolated enum RecordingEvents {
    /// Write the recording again, beside it as a `.mov`, with what happened
    /// in this run marked as chapters and captions; nil when it can't be.
    @discardableResult
    static func annotate(_ video: URL, firstFrame start: Date, gameSlug: String) -> URL? {
        guard FileManager.default.fileExists(atPath: video.path) else { return nil }
        let events = (ownEvents(LogStore.shared.snapshot().entries, since: start)
            + wrappEvents(launchLog(gameSlug: gameSlug, since: start), since: start)).sorted { $0.time < $1.time }
        let output = video.deletingPathExtension().appendingPathExtension("mov")
        do {
            try VideoAnnotator.annotate(video, events: events, to: output)
            logger.notice("🎥 Screen recording, with \(events.count) events marked: \(output.path)")
            return output
        } catch {
            logger.warning("Couldn't mark what happened in the screen recording: \(error)")
            return nil
        }
    }

    /// The words a step of this run's starts with, in its log: the rest is
    /// detail (each search, each look for a process).
    static let stepMarks = ["[Step", "🚀", "✅", "❌", "✓", "⚠️", "⏳", "🔀", "📸", "🖼️", "🎮", "WRAPP_PUPPETEER: run_failed"]

    /// This run's steps, from its own log.
    static func ownEvents(_ entries: [Entry], since start: Date) -> [VideoAnnotator.Event] {
        entries.compactMap { entry in
            let message = entry.message.trimmingCharacters(in: .whitespaces)
            guard entry.level != "debug", entry.level != "trace", entry.timestamp >= start,
                  stepMarks.contains(where: message.hasPrefix) else { return nil }
            return VideoAnnotator.Event(time: entry.timestamp.timeIntervalSince(start), text: "Puppeteer: " + message)
        }
    }

    /// The categories of the wrapp's log that say how its launch went: Wine's
    /// own lines and the puppet server's chatter are left out.
    static let wrappCategories = [".main", ".GameLauncher", ".InfoWindow", ".Steam", ".BigFish"]

    /// The wrapp's launch, from its launch log's lines
    /// (`2026-11-04T00:56:14.678Z  notice  <label>  <message>`).
    static func wrappEvents(_ log: String, since start: Date) -> [VideoAnnotator.Event] {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return log.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let time = parser.date(from: parts[0]), time >= start else { return nil }
            let rest = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard rest.count == 2, !["debug", "trace"].contains(rest[0]) else { return nil }
            let fields = rest[1].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard fields.count == 2, wrappCategories.contains(where: fields[0].hasSuffix) else { return nil }
            let message = fields[1].trimmingCharacters(in: .whitespaces)
            guard !message.hasPrefix("[Puppet]") else { return nil }
            return VideoAnnotator.Event(time: time.timeIntervalSince(start), text: "App: " + message)
        }
    }

    /// The wrapp's launch log for this run: its newest, begun since the
    /// recording started (`~/Library/Logs/SecondChance/<slug>/launch-*.log`).
    static func launchLog(gameSlug: String, since start: Date) -> String {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SecondChance/\(gameSlug)", isDirectory: true)
        let logs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = logs.filter { $0.lastPathComponent.hasPrefix("launch-") && $0.pathExtension == "log" }
            .compactMap { url -> (URL, Date)? in
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= start else { return nil }
                return (url, modified)
            }
            .max { $0.1 < $1.1 }
        return newest.flatMap { try? String(contentsOf: $0.0, encoding: .utf8) } ?? ""
    }
}
