//
//  Wine.swift
//  Shared
//
//  One Wine and the prefix it runs in: where its programs are, the
//  environment they run with, and running them. Used by Second Chance's
//  build and by the wrapp.

import Foundation
import Logging

/// Fixed label: `Shared/` compiles into three targets with three different
/// subsystems, so this file cannot pick one — a stable `.Shared` leaf still
/// matches `BEGINSWITH 'au.gare.callum.second-chance'`.
private nonisolated let wineLogger = Logger(label: "au.gare.callum.second-chance.Shared.Wine")
/// What Wine and the Windows programs it runs print, as its own category so
/// it can be told apart from Second Chance's lines about running it.
private nonisolated let wineOutputLogger = Logger(label: "au.gare.callum.second-chance.Shared.Wine")

/// A wrapp's Wine and the prefix it runs in.
nonisolated public struct Wine: Sendable {
    let wineDir: URL
    let binDir: URL
    let prefix: URL
    let frameworksDir: URL

    /// The Windows user name: whose folder under `drive_c/users` the saves are in.
    public static let username = "crossover"

    /// `WINEDEBUG` when `SECOND_CHANCE_WINEDEBUG` is unset: every channel
    /// off except the err class. See docs/logging.md.
    static let defaultWineDebug = "-all,err+all"

    /// The Wine bundled in `wrapp`, running in `prefix`: the wrapp's own
    /// unless given another.
    public init(wrapp: URL, prefix: URL? = nil) {
        self.wineDir = wrapp.appendingPathComponent("Contents/SharedSupport/wine")
        self.binDir = wineDir.appendingPathComponent("bin")
        self.prefix = prefix ?? wrapp.appendingPathComponent("Contents/SharedSupport/prefix")
        self.frameworksDir = wrapp.appendingPathComponent("Contents/Frameworks")
    }

    /// The variables Second Chance sets for Wine, and only those.
    public var variables: [String: String] {
        let dyldFallbackLibraryPath = [
            frameworksDir.appendingPathComponent("moltenvkcx").path,
            wineDir.appendingPathComponent("lib").path,
            wineDir.appendingPathComponent("lib/external").path,
            wineDir.appendingPathComponent("lib64").path,
            frameworksDir.appendingPathComponent("d3dmetal/external").path,
            frameworksDir.path,
            "/opt/wine/lib",
            frameworksDir.appendingPathComponent("GStreamer.framework/Libraries").path,
            "/usr/lib",
            "/usr/libexec",
            "/usr/lib/system",
            "/opt/X11/lib"
        ].joined(separator: ":")

        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""

        // Only Wine's err class by default: it costs a line or two on a
        // healthy run, and it is where Wine names the cause when something
        // fails (a DLL that won't load, no graphics driver outside the GUI
        // session). SECOND_CHANCE_WINEDEBUG replaces it with other channels
        // (e.g. "+seh,+d3d9"). Deliberately not plain WINEDEBUG, which a user
        // may have set in their shell for some other Wine.
        let wineDebug = ProcessInfo.processInfo.environment["SECOND_CHANCE_WINEDEBUG"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultWineDebug

        return [
            "WINEPREFIX": prefix.path,
            "WINE": binDir.appendingPathComponent("wine").path,
            "USER": Self.username,
            "WINEDEBUG": wineDebug,
            "PATH": "\(binDir.path):\(originalPath):/opt/local/bin:/opt/local/sbin",
            "DYLD_FALLBACK_LIBRARY_PATH": dyldFallbackLibraryPath,
            "GST_PLUGIN_PATH": frameworksDir.appendingPathComponent("GStreamer.framework/Libraries/gstreamer-1.0").path,
            "WINETRICKS_FALLBACK_LIBRARY_PATH": dyldFallbackLibraryPath,
            "WINEBOOT_HIDE_DIALOG": "1",
            "CX_ROOT": wineDir.path,
            "MVK_CONFIG_RESUME_LOST_DEVICE": "1",
            // MoltenVK logs at info by default: ~160 lines of extension and
            // GPU listings per launch. Warnings and errors still come through.
            "MVK_CONFIG_LOG_LEVEL": "2",
            "MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE": "1",
            "WINEESYNC": "1",
            "WINEMSYNC": "1",
            "MTL_HUD_ENABLED": "0",
            "MVK_CONFIG_FAST_MATH_ENABLED": "0",
            "DOTNET_EnableWriteXorExecute": "0"
        ]
    }

    /// What a Wine program runs with: ours over the parent's.
    public var environment: [String: String] {
        ProcessInfo.processInfo.environment.merging(variables) { $1 }
    }

    /// Run a Wine executable
    @discardableResult
    public func runExecutable(_ executable: String, arguments: [String] = []) -> Int32 {
        let executablePath = binDir.appendingPathComponent(executable)

        let process = Process()
        process.executableURL = executablePath
        process.arguments = arguments
        process.environment = environment
        // Explicitly inherit the parent's stdio. Foundation nominally does this by
        // default, but in practice it's unreliable (notably for a GUI-app binary
        // invoked directly from a terminal). Wiring the handles explicitly ensures
        // stdin/stdout/stderr reach the child — e.g. so interactive Wine tools run
        // via the `wine` subcommand (wine cmd, wine regedit, etc.) work as expected.
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.runWithoutCrashHandler()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            wineLogger.error("ERROR: Failed to run \(executable): \(error)")
            return -1
        }
    }

    /// Run a Wine program and wait for it, streaming its output into the
    /// log line by line as it arrives.
    ///
    /// The log gets one `▶` line when it starts (with its pid and arguments),
    /// a `…` heartbeat whenever it has been quiet for 30 s, and one `■` line
    /// saying how it ended — exit code or signal, how long it ran, how much
    /// it printed. Its output is logged under the `Wine` category.
    ///
    /// Throws `WineError.executionFailed` on a non-zero exit,
    /// `.terminatedBySignal` when it was killed, `.timedOut` when `timeout`
    /// passes first, and `.stalled` when `watchdog` says it has stopped
    /// getting anywhere — in both of which the prefix's wineserver is
    /// stopped, which ends every Windows process in it.
    public func runWine(
        executable: String,
        arguments: [String] = [],
        timeout: TimeInterval? = nil,
        watchdog: WineWatchdog? = nil
    ) async throws {
        let winePath = binDir.appendingPathComponent(executable)

        guard FileManager.default.fileExists(atPath: winePath.path) else {
            throw NSError(domain: "Wine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: """
                Wine framework not found at: \(winePath.path)

                To use this app, you need to bundle Wine:
                1. Download CrossOver or extract Wine from Wineskin
                2. Copy the wine folder to: Second Chance.app/Contents/SharedSupport/wine/
                3. The structure should be: Second Chance.app/Contents/SharedSupport/wine/bin/wine

                Or run from Xcode: copy wine to the app's built location.
                """
            ])
        }
        guard FileManager.default.isExecutableFile(atPath: winePath.path) else {
            wineLogger.error("Wine at \(winePath.path) is not executable")
            throw WineError.executionFailed(exitCode: 126)
        }

        let env = environment
        let quotedArguments = arguments.map { "\"\($0)\"" }.joined(separator: " ")

        // Run through /bin/sh so Wine gets exactly these variables exported,
        // whatever the parent's environment holds.
        let shellScript = """
        export WINEPREFIX="\(env["WINEPREFIX"] ?? "")"
        export WINE="\(env["WINE"] ?? "")"
        export DYLD_FALLBACK_LIBRARY_PATH="\(env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "")"
        export PATH="\(env["PATH"] ?? "")"
        export WINEDEBUG="\(env["WINEDEBUG"] ?? "")"
        export WINEBOOT_HIDE_DIALOG="\(env["WINEBOOT_HIDE_DIALOG"] ?? "")"
        export CX_ROOT="\(env["CX_ROOT"] ?? "")"
        export USER="\(env["USER"] ?? "")"
        export WINEESYNC="\(env["WINEESYNC"] ?? "")"
        export WINEMSYNC="\(env["WINEMSYNC"] ?? "")"
        exec "\(winePath.path)" \(quotedArguments)
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellScript]
        process.environment = env

        // What someone would paste into a terminal to run it again: only the
        // variables Second Chance sets, not the whole parent environment.
        wineLogger.debug("To re-run by hand:\n\(reproductionCommand(winePath: winePath, arguments: arguments))")

        let watch = SubprocessWatch(name: Self.displayName(executable: executable, arguments: arguments), logger: wineLogger)
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let eofs = DispatchGroup()
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.runWithoutCrashHandler()
        } catch {
            wineLogger.error("Could not start \(watch.name): \(error)")
            throw error
        }
        watch.started(pid: process.processIdentifier, detail: arguments.joined(separator: " "))

        // Attached once the pid is known, so every line carries it; the pipes
        // hold anything written in the meantime.
        let metadata: Logger.Metadata = ["pid": "\(process.processIdentifier)", "program": "\(watch.name)"]
        let noDisplay = NoDisplaySignal()
        let onLine: @Sendable (String) -> Void = { line in
            watch.sawLine()
            noDisplay.check(line)
            watchdog?.sawOutput()
        }
        eofs.enter()
        eofs.enter()
        ProcessLineLogger.attach(to: outputPipe, logger: wineOutputLogger, level: .notice, metadata: metadata,
                                 onLine: onLine, onEOF: { eofs.leave() })
        ProcessLineLogger.attach(to: errorPipe, logger: wineOutputLogger, level: .warning, metadata: metadata,
                                 onLine: onLine, onEOF: { eofs.leave() })

        // Cancelling the task (the person cancelling a build) ends the
        // program's whole Wine session, as a timeout does.
        let ending: WaitEnding = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let ending = Self.wait(for: exited, timeout: timeout, watchdog: watchdog)
                    switch ending {
                    case .exited:
                        continuation.resume(returning: ending)
                        return
                    case .timedOut:
                        wineLogger.error("\(watch.name) did not finish within \(SubprocessWatch.duration(timeout ?? 0)) — stopping its Wine session")
                    case .stalled(let quietFor):
                        wineLogger.error("\(watch.name) showed no sign of progress for \(SubprocessWatch.duration(quietFor)) — stopping its Wine session")
                    }
                    // What was still running, before it is killed: a hung
                    // installer is often waiting on another Windows process.
                    wineLogger.warning("Wine processes when it was stopped:\n\(Self.wineProcessSnapshot())")
                    _ = self.stopWineserver()
                    process.terminate()
                    if exited.wait(timeout: .now() + 10) != .success {
                        kill(process.processIdentifier, SIGKILL)
                        exited.wait()
                    }
                    continuation.resume(returning: ending)
                }
            }
        } onCancel: {
            wineLogger.notice("Cancelled: stopping \(watch.name) and its Wine session")
            _ = self.stopWineserver()
            process.terminate()
        }

        // Let the last lines through. Wine's background services inherit the
        // pipes and hold them open until the wineserver exits (a few seconds
        // after the last Windows process), so EOF may never come promptly;
        // don't wait for it longer than that.
        _ = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: eofs.wait(timeout: .now() + 5))
            }
        }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        let note: String? = switch ending {
        case .timedOut: "timed out"
        case .stalled: "stalled"
        case .exited: Task.isCancelled ? "cancelled" : nil
        }
        let outcome = watch.finished(process, note: note)
        try Task.checkCancellation()
        switch ending {
        case .timedOut: throw WineError.timedOut(seconds: timeout ?? 0)
        case .stalled(let quietFor): throw WineError.stalled(quietFor: quietFor)
        case .exited: break
        }
        // Whatever the exit code: a program that couldn't open a window has
        // not done its job, and AutoIt in that state exits 0 without running
        // its script.
        if noDisplay.seen {
            throw WineError.noDisplay
        }
        switch outcome {
        case .exited(0):
            return
        case .exited(let code):
            throw WineError.executionFailed(exitCode: code)
        case .signalled(let signal):
            throw WineError.terminatedBySignal(signal)
        }
    }

    enum WaitEnding: Equatable {
        case exited
        case timedOut
        case stalled(quietFor: TimeInterval)
    }

    /// Wait for the program to exit, for `timeout` to pass, or for `watchdog`
    /// to say it has stalled, asking the watchdog every `tick` seconds. Time
    /// the watchdog says is spent waiting on the person doesn't count towards
    /// the timeout.
    static func wait(for exited: DispatchSemaphore, timeout: TimeInterval?, watchdog: WineWatchdog?,
                     tick: TimeInterval = 5) -> WaitEnding {
        guard let watchdog else {
            let deadline: DispatchTime = timeout.map { .now() + $0 } ?? .distantFuture
            return exited.wait(timeout: deadline) == .success ? .exited : .timedOut
        }
        var remaining = timeout
        while true {
            let slice = remaining.map { min(tick, max(0, $0)) } ?? tick
            if exited.wait(timeout: .now() + slice) == .success { return .exited }
            switch watchdog.check() {
            case .carryOn:
                remaining = remaining.map { $0 - slice }
            case .waitingOnPerson:
                break
            case .stalled(let quietFor):
                return .stalled(quietFor: quietFor)
            }
            if let left = remaining, left <= 0 { return .timedOut }
        }
    }

    /// `ps` lines for every Wine-related process: pid, parent, CPU, elapsed
    /// time and command.
    static func wineProcessSnapshot() -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid,ppid,pcpu,etime,command"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do {
            // swiftlint:disable:next wine_without_crash_handler
            try ps.run()  // ps, not Wine
        } catch {
            return "(couldn't run ps: \(error.localizedDescription))"
        }
        // Read before waiting: the list can be bigger than the pipe's buffer.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        let lines = output.split(separator: "\n")
        let wine = lines.dropFirst().filter { $0.contains("wine") || $0.lowercased().contains(".exe") }
        return ([lines.first.map(String.init) ?? ""] + wine.map { "  " + String($0.prefix(240)) }).joined(separator: "\n")
    }

    /// `wine setup.exe`, `wine reg`, `wineserver`: what to call a Wine run in
    /// the log. For `start`, the program it starts.
    static func displayName(executable: String, arguments: [String]) -> String {
        guard executable == "wine" else { return executable }
        var rest = arguments[...]
        if rest.first?.lowercased() == "start" {
            rest = rest.dropFirst()
            while let flag = rest.first, flag.hasPrefix("/"), ["/wait", "/unix", "/min", "/max", "/b"].contains(flag.lowercased()) {
                rest = rest.dropFirst()
            }
        }
        guard let program = rest.first else { return "wine" }
        let name = program.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? program
        return "wine \(name)"
    }

    /// A shell command that runs `winePath` with the variables Second Chance
    /// sets, one per line.
    func reproductionCommand(winePath: URL, arguments: [String]) -> String {
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let variables = variables
            .sorted { $0.key < $1.key }
            .map { "  \($0.key)=\(quote($0.value)) \\" }
        return (["env \\"] + variables + ["  " + ([winePath.path] + arguments).map(quote).joined(separator: " ")])
            .joined(separator: "\n")
    }

    /// Run a Windows executable with wine start /wait (async version using runWine)
    public func runWindowsExecutableWithStartAsync(
        exePath: String,
        arguments: [String] = [],
        timeout: TimeInterval? = nil,
        watchdog: WineWatchdog? = nil
    ) async throws {
        let args = ["start", "/wait", "/unix", exePath] + arguments
        try await runWine(executable: "wine", arguments: args, timeout: timeout, watchdog: watchdog)
    }

    /// Run a Windows executable with wine start /wait (synchronous version for WrappTemplate)
    /// Returns the Process object for async monitoring
    public func runWindowsExecutableWithStart(
        exePath: String,
        arguments: [String] = [],
        outputPipe: Pipe? = nil,
        errorPipe: Pipe? = nil
    ) throws -> Process {
        let wineExecutable = binDir.appendingPathComponent("wine")
        let exeURL = URL(fileURLWithPath: exePath)
        let exeDir = exeURL.deletingLastPathComponent().path
        let exeFileName = exeURL.lastPathComponent

        // Use just the filename, not /unix path
        let args = ["start", "/wait", exeFileName] + arguments

        let process = Process()
        process.executableURL = wineExecutable
        process.arguments = args

        process.environment = environment.merging(Self.inProcessHelperVariables(gameExe: exeURL)) { $1 }
        process.currentDirectoryURL = URL(fileURLWithPath: exeDir)

        if let outputPipe = outputPipe {
            process.standardOutput = outputPipe
        }
        if let errorPipe = errorPipe {
            process.standardError = errorPipe
        }

        try process.runWithoutCrashHandler()
        return process
    }

    // MARK: - Desktop

    /// Start Wine's desktop process (`explorer.exe /desktop`) for this prefix.
    ///
    /// Wine starts it on demand the first time a program needs the desktop
    /// window, and waits at most 10 seconds for it to become ready. On a busy
    /// machine under Rosetta it can take longer, and a game that carries on
    /// before the desktop has registered the display devices finds no display
    /// adapters (Secrets Can Kill Remastered then crashes on a null Direct3D
    /// object). Starting it first and waiting with `displayDevicesRegistered()`
    /// takes that race away. It exits by itself once the last program in the
    /// session has.
    public func startDesktop(outputPipe: Pipe? = nil, errorPipe: Pipe? = nil) throws -> Process {
        let process = Process()
        process.executableURL = binDir.appendingPathComponent("wine")
        process.arguments = ["explorer.exe", "/desktop"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        if let outputPipe { process.standardOutput = outputPipe }
        if let errorPipe { process.standardError = errorPipe }
        try process.runWithoutCrashHandler()
        return process
    }

    /// Outcome of one `displayDevicesRegistered` check, for logging.
    public enum DisplayQueryResult: Equatable {
        case registered
        case notYet(exitCode: Int32)
        case timedOut
        case failedToRun(String)
    }

    /// Whether the desktop process has registered the display devices — the
    /// point after which Direct3D can enumerate adapters.
    public func displayDevicesRegistered(timeout: TimeInterval = 20) -> Bool {
        queryDisplayDevices(timeout: timeout) == .registered
    }

    /// `displayDevicesRegistered`, with the reason when it isn't.
    ///
    /// `HKLM\HARDWARE\DEVICEMAP\VIDEO` is volatile: wineserver starts with it
    /// empty and the desktop process fills it in while initialising the display.
    /// Each call runs `reg.exe`, about a second. Output goes to a file rather
    /// than a pipe because Wine's background services inherit the child's stdout
    /// and would hold a pipe open forever.
    public func queryDisplayDevices(timeout: TimeInterval = 20) -> DisplayQueryResult {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("second-chance-display-query-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL) else {
            return .failedToRun("could not create \(outputURL.path)")
        }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = binDir.appendingPathComponent("wine")
        process.arguments = ["reg", "query", #"HKLM\HARDWARE\DEVICEMAP\VIDEO"#]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.runWithoutCrashHandler()
        } catch {
            return .failedToRun("\(error)")
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return .timedOut
        }
        let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        if process.terminationStatus == 0 && text.contains(#"\Device\Video"#) {
            return .registered
        }
        return .notYet(exitCode: process.terminationStatus)
    }

    /// Check if wineserver is running for this prefix
    public func isWineserverRunning() -> Bool {
        let wineserverPath = binDir.appendingPathComponent("wineserver")
        // A ScummVM wrapp has no Wine at all, so no wineserver to be running.
        guard FileManager.default.fileExists(atPath: wineserverPath.path) else { return false }

        let process = Process()
        process.executableURL = wineserverPath
        process.arguments = ["-k0"]  // Send null signal to check if server is running
        process.environment = environment

        do {
            try process.runWithoutCrashHandler()
            process.waitUntilExit()
            // wineserver -k0 returns 0 if server is running for this prefix
            return process.terminationStatus == 0
        } catch {
            wineLogger.error("Error checking for wineserver: \(error)")
            return false
        }
    }

    /// Stop wineserver for this prefix
    @discardableResult
    public func stopWineserver() -> Int32 {
        let wineserverPath = binDir.appendingPathComponent("wineserver")

        let process = Process()
        process.executableURL = wineserverPath
        process.arguments = ["-k"]  // Kill all Wine processes for this prefix
        process.environment = environment

        do {
            try process.runWithoutCrashHandler()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            wineLogger.error("Error stopping wineserver: \(error)")
            return -1
        }
    }
}

/// Watches a Wine program's output for `nodrv_CreateWindow`, the line Wine
/// prints when a program tries to open a window without a working desktop.
private nonisolated final class NoDisplaySignal: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false

    var seen: Bool { lock.withLock { flagged } }

    func check(_ line: String) {
        guard line.contains("nodrv_CreateWindow") else { return }
        lock.withLock { flagged = true }
    }
}
