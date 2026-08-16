//
//  LogStoreHandler.swift
//  Shared
//
//  swift-log handler that stamps timestamps and appends to LogStore.

import Foundation
import Logging

nonisolated struct LogStoreHandler: LogHandler {

    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    private let label: String

    init(label: String) {
        self.label = label
    }

    nonisolated func log(event: Logging.LogEvent) {
        // Flatten immediately: store String, never Logger.Message or (any Error)?
        // (retaining errors in a 50k ring pins arbitrary object graphs).
        LogStore.shared.append(
            level: Self.levelToString(event.level),
            label: label,
            message: event.message.description,
            error: event.error.map { String(describing: $0) }
        )
    }

    nonisolated subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    // MARK: - Private

    private static func levelToString(_ level: Logging.Logger.Level) -> String {
        switch level {
        case .trace: return "trace"
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .warning: return "warning"
        case .error: return "error"
        case .critical: return "critical"
        }
    }
}
