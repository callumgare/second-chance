//
//  InstallerLogStreamer.swift
//  SecondChance
//
//  Following an installer's own log as it is written.

import Foundation
import Logging
import SecondChanceKit

/// Which installer log `InstallerLogStreamer` is following.
nonisolated enum InstallerLogFormat: Sendable {
    case msi
    case inno

    /// Nil for installers whose log Second Chance doesn't read.
    init?(_ installerType: InstallerType) {
        switch installerType {
        case .msi: self = .msi
        case .innoSetup: self = .inno
        case .installShield, .unknown: return nil
        }
    }

    var name: String {
        switch self {
        case .msi: return "MSI"
        case .inno: return "Inno Setup"
        }
    }
}

/// Follows an installer's own log (`tail -F`) into the log. msiexec writes a
/// line or two for every file it installs — 97% of the lines in a run that
/// installed several games — and Inno Setup four, so those go in at debug,
/// and the lines that say how the install went (failed actions, errors, the
/// final verdict) at notice or error. `stop()` logs a one-line summary.
nonisolated final class InstallerLogStreamer: @unchecked Sendable {
    private let logPath: URL
    private let format: InstallerLogFormat
    private let process = Process()
    private let logger: Logger
    private let lock = NSLock()
    private var lines = 0
    private var files = 0
    private var errors = 0
    /// Called with each line too, after it is counted. Set before `start()`.
    var onLine: (@Sendable (String) -> Void)?

    init(logPath: URL, format: InstallerLogFormat) {
        self.logPath = logPath
        self.format = format
        let suffix = format == .msi ? "msi-log" : "inno-log"
        self.logger = Logger(label: "au.gare.callum.second-chance.SecondChance.GameInstallerRunner.\(suffix)")
    }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        process.arguments = ["-n", "+1", "-F", logPath.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let format = format
        ProcessLineLogger.attach(
            to: pipe, logger: logger, level: .debug,
            levelFor: { Self.notableLevel(of: $0, format: format) ?? .debug },
            onLine: { [weak self, onLine] line in
                self?.count(line)
                onLine?(line)
            }
        )
        try process.run()
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        let (lines, files, errors) = lock.withLock { (self.lines, self.files, self.errors) }
        logger.notice("\(format.name) log: \(lines) lines, \(files) files installed, \(errors) error line\(errors == 1 ? "" : "s")")
    }

    /// The level a line deserves beyond the debug copy it already got.
    static func notableLevel(of line: String, format: InstallerLogFormat) -> Logger.Level? {
        switch format {
        case .msi:
            if line.contains("Return value 3") || line.hasPrefix("Error ") || line.contains("Installation failed")
                || line.contains("-- Installation operation failed") {
                return .error
            }
            if line.contains("Installation completed successfully") || line.contains("-- Installation operation completed")
                || line.hasPrefix("MSI (") && line.contains("Product:") || line.contains(": INSTALL. Return value") {
                return .notice
            }
        case .inno:
            // Lines start with a timestamp: "2026-10-16 20:25:22.993   …".
            if line.contains("Exception message:") || line.contains("Installation process failed")
                || line.contains("Fatal exception") || line.contains("Setup is aborting") {
                return .error
            }
            if line.contains(InstallCompletion.innoSuccessLine) || line.contains("Setup version: ")
                || line.contains("Original Setup EXE: ") {
                return .notice
            }
        }
        return nil
    }

    private func count(_ line: String) {
        let isFile = switch format {
        case .msi: line.hasPrefix("File: ") && line.contains("Size:")
        case .inno: line.contains("Successfully installed the file.")
        }
        let isError = Self.notableLevel(of: line, format: format) == .error
        lock.withLock {
            lines += 1
            if isFile { files += 1 }
            if isError { errors += 1 }
        }
    }
}
