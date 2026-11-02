//
//  RunContext.swift
//  WrappLogging
//
//  What every log should say first: which build, on what machine, in what
//  kind of session — and a run ID that ties the log of a build to the logs
//  of the processes it started. Most "it worked yesterday" failures turn
//  out to be one of these. The header itself, which also names Wine's
//  settings and the Mac's load, is SecondChanceKit's (RunContext+Header).

import Foundation
import CoreGraphics
import Logging

nonisolated public enum RunContext {

    /// Identifies this run in every log it writes. Inherited from
    /// `SECOND_CHANCE_RUN_ID` when a parent (sc, the app) set it, so one ID
    /// covers a build and everything it started; otherwise generated, and
    /// exported so children inherit it.
    public static let runID: String = {
        if let inherited = ProcessInfo.processInfo.environment["SECOND_CHANCE_RUN_ID"], !inherited.isEmpty {
            return inherited
        }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        setenv("SECOND_CHANCE_RUN_ID", id, 1)
        return id
    }()

    /// The launchd session this process runs in: `Aqua` for the logged-in
    /// GUI, `Background` for an SSH shell, nil if it can't be told.
    public static let launchdSession: String? = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["managername"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }()

    /// Whether this process can open windows. Outside the Aqua session (an
    /// SSH shell's Background session) Wine can't load its graphics driver,
    /// and installers fail with nothing but an exit code. The console
    /// user's CoreGraphics session is visible from there too, so that can't
    /// tell; launchd's session type can.
    public static var hasWindowServerSession: Bool {
        guard let session = launchdSession else { return CGSessionCopyCurrentDictionary() != nil }
        return session == "Aqua"
    }

    /// Whether this is a Debug build, which reports nothing and doesn't look
    /// for updates. Decided where this module is compiled, which is always
    /// in the same configuration as the app linking it.
    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Whether this process runs translated by Rosetta.
    public static var isTranslated: Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
    }

    /// This process's architecture: `arm64`, `x86_64`, or `x86_64 under Rosetta`.
    public static var processArchitecture: String {
        #if arch(x86_64)
        return isTranslated ? "x86_64 under Rosetta" : "x86_64"
        #else
        return "arm64"
        #endif
    }

    /// The Mac's model identifier (`Mac14,2`).
    public static func machineModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown Mac" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown Mac" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
