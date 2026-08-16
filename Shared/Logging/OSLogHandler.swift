//
//  OSLogHandler.swift
//  Shared
//
//  Synchronous swift-log handler that forwards to os.Logger.
//  This is crash-durable and the only place with privacy: .public annotations.

import Foundation
import os
import Logging

nonisolated struct OSLogHandler: LogHandler {

    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    /// The os.Logger for this handler's label. Handlers are created per-Logger
    /// by the bootstrap factory, so one instance per label is exactly right.
    private let osLogger: os.Logger

    init(label: String) {
        let (subsystem, category) = Self.splitLabel(label)
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
    }

    nonisolated func log(event: Logging.LogEvent) {
        // Emit with privacy: .public — this is the single most consequential line in the change.
        // Getting this wrong redacts everything in release builds and breaks every log show test.
        let text = event.message.description
        osLogger.log(level: Self.mapLevel(event.level), "\(text, privacy: .public)")
    }

    nonisolated subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    // MARK: - Private

    /// Split label at last dot to get (subsystem, category).
    /// Example: "au.gare.callum.second-chance.SecondChance.GameDetector"
    /// → subsystem: "au.gare.callum.second-chance.SecondChance"
    ///   category: "GameDetector"
    private static func splitLabel(_ label: String) -> (String, String) {
        guard let lastDot = label.lastIndex(of: ".") else {
            return (label, label)
        }

        let subsystem = String(label[..<lastDot])
        let category = String(label[label.index(after: lastDot)...])

        return (subsystem, category)
    }

    /// Map swift-log Logger.Level to OSLogType.
    private static func mapLevel(_ level: Logging.Logger.Level) -> OSLogType {
        switch level {
        case .trace:
            return .debug  // No .trace in OSLogType
        case .debug:
            return .debug
        case .info:
            return .info
        case .notice:
            return .default  // .notice maps to .default
        case .warning:
            return .error  // No .warning in OSLogType
        case .error:
            return .error
        case .critical:
            return .fault
        }
    }
}
