//
//  MultiplexLogHandler.swift
//  Shared
//
//  Multiplexing swift-log handler that forwards to both LogStoreHandler and OSLogHandler.

import Foundation
import Logging

/// Multiplexes log events to both LogStore (in-process storage) and OSLog (crash-durable).
/// OSLog is called synchronously on the emitting thread — os_log captures the calling
/// thread, and anything sitting in a queue at crash time is lost.
nonisolated struct MultiplexLogHandler: LogHandler {

    var metadata: Logging.Logger.Metadata {
        get { logStoreHandler.metadata }
        set {
            logStoreHandler.metadata = newValue
            osLogHandler.metadata = newValue
        }
    }

    var logLevel: Logging.Logger.Level {
        get { logStoreHandler.logLevel }
        set {
            logStoreHandler.logLevel = newValue
            osLogHandler.logLevel = newValue
        }
    }

    private var logStoreHandler: LogStoreHandler
    private var osLogHandler: OSLogHandler

    init(label: String) {
        self.logStoreHandler = LogStoreHandler(label: label)
        self.osLogHandler = OSLogHandler(label: label)
    }

    /// Under Xcode and xcodebuild's test runs (`OS_ACTIVITY_DT_MODE`), os_log
    /// copies every entry to stderr itself, beside LogStore's copy: each line
    /// appeared twice in two formats, torn where the two writers met. There,
    /// LogStore's copy (the one that honours `SECOND_CHANCE_LOG_LEVEL`) is the
    /// only one; os_log has already latched the variable, so unsetting it
    /// wouldn't help.
    static let writesToOSLog = ProcessInfo.processInfo.environment["OS_ACTIVITY_DT_MODE"] == nil

    nonisolated func log(event: Logging.LogEvent) {
        // OSLog first for crash durability (synchronous, on the emitting thread).
        if Self.writesToOSLog {
            osLogHandler.log(event: event)
        }

        // Then LogStore for in-process delivery (drains on its serial queue).
        logStoreHandler.log(event: event)
    }

    nonisolated subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get {
            logStoreHandler[metadataKey: key]
        }
        set {
            logStoreHandler[metadataKey: key] = newValue
            osLogHandler[metadataKey: key] = newValue
        }
    }
}
