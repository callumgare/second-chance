//
//  RunContext.swift
//  Shared
//
//  What every log should say first: which build, on what machine, in what
//  kind of session, with which Wine settings — and a run ID that ties the
//  log of a build to the logs of the processes it started. Most "it worked
//  yesterday" failures turn out to be one of these.

import Foundation
import CoreGraphics
import Logging

nonisolated enum RunContext {

    /// Identifies this run in every log it writes. Inherited from
    /// `SECOND_CHANCE_RUN_ID` when a parent (sc, the app) set it, so one ID
    /// covers a build and everything it started; otherwise generated, and
    /// exported so children inherit it.
    static let runID: String = {
        if let inherited = ProcessInfo.processInfo.environment["SECOND_CHANCE_RUN_ID"], !inherited.isEmpty {
            return inherited
        }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        setenv("SECOND_CHANCE_RUN_ID", id, 1)
        return id
    }()

    /// The launchd session this process runs in: `Aqua` for the logged-in
    /// GUI, `Background` for an SSH shell, nil if it can't be told.
    static let launchdSession: String? = {
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
    static var hasWindowServerSession: Bool {
        guard let session = launchdSession else { return CGSessionCopyCurrentDictionary() != nil }
        return session == "Aqua"
    }

    /// Whether this process runs translated by Rosetta.
    static var isTranslated: Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
    }

    /// The lines of the header, without logging them.
    static func headerLines(extra: [(String, String)] = []) -> [String] {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleName"] as? String ?? ProcessInfo.processInfo.processName
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(x86_64)
        let arch = isTranslated ? "x86_64 under Rosetta" : "x86_64"
        #else
        let arch = "arm64"
        #endif
        let session = hasWindowServerSession
            ? "GUI session (\(launchdSession ?? "unknown"))"
            : "no GUI session (\(launchdSession ?? "unknown")) — Wine can't open windows here (run through `sc in-gui-session`)"
        let wineDebug = ProcessInfo.processInfo.environment["SECOND_CHANCE_WINEDEBUG"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? WineEnvironment.defaultWineDebug

        var lines = [
            "\(name) \(version) (build \(build)), pid \(ProcessInfo.processInfo.processIdentifier), run \(runID)",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(machineModel()), process \(arch)",
            "\(session); WINEDEBUG=\(wineDebug)",
            // A busy Mac is the likeliest cause of a slow or failed Wine start.
            "load: \(SystemLoad.read().map(\.summary) ?? "unknown (ps failed)")",
        ]
        lines += extra.map { "\($0.0): \($0.1)" }
        return lines
    }

    /// Log the header as one entry, so it reads as a block.
    static func logHeader(_ logger: Logging.Logger, extra: [(String, String)] = []) {
        let lines = headerLines(extra: extra)
        logger.notice("━━━ \(lines[0]) ━━━\n\(lines.dropFirst().map { "  \($0)" }.joined(separator: "\n"))")
        if !hasWindowServerSession {
            logger.warning("No GUI session: Wine programs that open windows (installers, games) will fail")
        }
        if let load = SystemLoad.read(), load.isHeavy {
            logger.warning("The Mac is heavily loaded: \(load.summary). Wine may take minutes to start programs, or fail to")
        }
    }

    private static func machineModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown Mac" }
        return String(cString: buffer)
    }
}
