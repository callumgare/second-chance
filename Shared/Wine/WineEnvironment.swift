//
//  WineEnvironment.swift
//  Shared Wine environment and execution logic
//
//  Used by both SecondChance app and WrappTemplate runtime

import Foundation
import Logging

/// Fixed label: `Shared/` compiles into three targets with three different
/// subsystems, so this file cannot pick one — a stable `.Shared` leaf still
/// matches `BEGINSWITH 'au.gare.callum.second-chance'`.
private nonisolated let wineLogger = Logger(label: "au.gare.callum.second-chance.Shared.WineEnvironment")
/// What Wine and the Windows programs it runs print, as its own category so
/// it can be told apart from Second Chance's lines about running it.
private nonisolated let wineOutputLogger = Logger(label: "au.gare.callum.second-chance.Shared.Wine")

/// Wine configuration and execution utilities
nonisolated public struct WineEnvironment: Sendable {
    let wineDir: URL
    let wineBinDir: URL
    let prefixDir: URL
    let frameworksDir: URL

    static let wineUsername = "crossover"

    /// `WINEDEBUG` when `SECOND_CHANCE_WINEDEBUG` is unset: every channel
    /// off except the err class. See docs/logging.md.
    static let defaultWineDebug = "-all,err+all"

    public init(appPath: URL, customPrefixDir: URL? = nil) {
        self.wineDir = appPath.appendingPathComponent("Contents/SharedSupport/wine")
        self.wineBinDir = wineDir.appendingPathComponent("bin")
        self.prefixDir = customPrefixDir ?? appPath.appendingPathComponent("Contents/SharedSupport/prefix")
        self.frameworksDir = appPath.appendingPathComponent("Contents/Frameworks")
    }

    /// Get only the Wine-specific environment variables (not all system vars)
    public func wineSpecificEnvironmentVariables() -> [String: String] {
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
            "WINEPREFIX": prefixDir.path,
            "WINE": wineBinDir.appendingPathComponent("wine").path,
            "USER": WineEnvironment.wineUsername,
            "WINEDEBUG": wineDebug,
            "PATH": "\(wineBinDir.path):\(originalPath):/opt/local/bin:/opt/local/sbin",
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

    /// The directory WrappPuppeteer gave the wrapp for its control sockets,
    /// when it started the wrapp; nil for every player's launch.
    public static func puppetDirectory(in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let directory = environment["SECOND_CHANCE_PUPPET_DIR"], !directory.isEmpty else { return nil }
        return directory
    }

    /// Variables a wrapp sets on itself at start-up, so that every Wine
    /// process it starts inherits them — the desktop, the game, Steam — and
    /// Second Chance's own installer runs don't.
    ///
    /// `NATIVE_FULLSCREEN_BELOW_NOTCH` shows Wine a notched display without the
    /// strip the notch sits in, which a fullscreen Space leaves out, so a game
    /// in one gets mouse positions that match its picture. It has to reach
    /// explorer.exe, which registers the displays the game sees, which is why
    /// it isn't among `inProcessHelperVariables`. Native fullscreen's off switch
    /// turns it off too.
    public static func wrappSessionVariables(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        guard environment["SECOND_CHANCE_NATIVE_FULLSCREEN"] != "0" else { return [:] }
        return ["NATIVE_FULLSCREEN_BELOW_NOTCH": "1"]
    }

    /// The variables that arm the in-process helpers bundled into Wine's Mac
    /// driver for the game whose .exe is at `gameExe`: native fullscreen puts
    /// the game's window into a real macOS fullscreen Space, cursor lock gets
    /// cnc-ddraw to take the mouse without swallowing the player's first click
    /// (only in a game that may draw through cnc-ddraw: `GameGraphicsAPI`),
    /// mode scaling scales a Direct3D game's picture up to the display when
    /// Wine is emulating the display mode the game switched to (only in a game
    /// that may draw with Direct3D), quit watch tells the wrapp when the game
    /// first drew and whether it was asked to quit, and puppet control (only when WrappPuppeteer
    /// started the wrapp) lets it see and click the game. Every Mac-driver
    /// process loads them, so each is told which one is the game (by the
    /// .exe's name, which Wine puts in the process's argv[0]), and a Wine
    /// program passes its environment on to the programs it starts — so these
    /// work set on Steam as well as on the game.
    /// See docs/wine-in-process-helpers.md.
    public static func inProcessHelperVariables(
        gameExe exeURL: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let gameExe = exeURL.lastPathComponent
        var env: [String: String] = [:]
        // SECOND_CHANCE_NATIVE_FULLSCREEN=0 leaves native fullscreen unarmed — a
        // debug switch for telling its main-thread polling apart from other causes.
        if environment["SECOND_CHANCE_NATIVE_FULLSCREEN"] != "0" {
            env["NATIVE_MACOS_FULLSCREEN_EXE"] = gameExe
        }
        // SECOND_CHANCE_CURSOR_LOCK=0 leaves cursor lock unarmed, bringing back
        // cnc-ddraw's swallowed first click — for comparison. A Direct3D game
        // never goes through cnc-ddraw, and the lock's middle clicks would
        // only close the menus a player opens from the menu bar.
        let graphicsAPI = GameGraphicsAPI(exeAt: exeURL)
        if environment["SECOND_CHANCE_CURSOR_LOCK"] != "0", graphicsAPI.mayUseCncDdraw {
            env["CURSOR_LOCK_EXE"] = gameExe
        }
        // SECOND_CHANCE_MODE_SCALING=0 leaves mode scaling unarmed, so a game
        // that switches the display mode draws into a corner of its window —
        // for comparison. The prefix's EmulateModeset (WineManager) stays on.
        if environment["SECOND_CHANCE_MODE_SCALING"] != "0", graphicsAPI.mayUseDirect3D {
            env["EMULATED_MODE_SCALING_EXE"] = gameExe
        }
        // Quit watch only reports, so it has no off switch: what it says
        // lets the wrapp tell a game that quit before it drew anything from
        // a player quitting (GameQuitCheck).
        env["QUIT_WATCH_EXE"] = gameExe
        // Puppet control arms only when WrappPuppeteer started the wrapp,
        // which it marks by passing the directory for the helper's socket.
        if puppetDirectory(in: environment) != nil {
            env["PUPPET_CONTROL_EXE"] = gameExe
        }
        return env
    }

    /// Generate Wine environment variables (includes system vars + Wine-specific vars)
    public func environmentVariables() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // Merge in Wine-specific variables
        for (key, value) in wineSpecificEnvironmentVariables() {
            env[key] = value
        }

        return env
    }

    /// Run a Wine executable
    @discardableResult
    public func runExecutable(_ executable: String, arguments: [String] = []) -> Int32 {
        let executablePath = wineBinDir.appendingPathComponent(executable)

        let process = Process()
        process.executableURL = executablePath
        process.arguments = arguments
        process.environment = environmentVariables()
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
        let winePath = wineBinDir.appendingPathComponent(executable)

        guard FileManager.default.fileExists(atPath: winePath.path) else {
            throw NSError(domain: "WineEnvironment", code: 1, userInfo: [
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

        let env = environmentVariables()
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
        let variables = wineSpecificEnvironmentVariables()
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
        let wineExecutable = wineBinDir.appendingPathComponent("wine")
        let exeURL = URL(fileURLWithPath: exePath)
        let exeDir = exeURL.deletingLastPathComponent().path
        let exeFileName = exeURL.lastPathComponent

        // Use just the filename, not /unix path
        let args = ["start", "/wait", exeFileName] + arguments

        let process = Process()
        process.executableURL = wineExecutable
        process.arguments = args

        process.environment = environmentVariables().merging(Self.inProcessHelperVariables(gameExe: exeURL)) { $1 }
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
        process.executableURL = wineBinDir.appendingPathComponent("wine")
        process.arguments = ["explorer.exe", "/desktop"]
        process.environment = environmentVariables()
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
        process.executableURL = wineBinDir.appendingPathComponent("wine")
        process.arguments = ["reg", "query", #"HKLM\HARDWARE\DEVICEMAP\VIDEO"#]
        process.environment = environmentVariables()
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
        let wineserverPath = wineBinDir.appendingPathComponent("wineserver")
        // A ScummVM wrapp has no Wine at all, so no wineserver to be running.
        guard FileManager.default.fileExists(atPath: wineserverPath.path) else { return false }

        let process = Process()
        process.executableURL = wineserverPath
        process.arguments = ["-k0"]  // Send null signal to check if server is running
        process.environment = environmentVariables()

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
        let wineserverPath = wineBinDir.appendingPathComponent("wineserver")

        let process = Process()
        process.executableURL = wineserverPath
        process.arguments = ["-k"]  // Kill all Wine processes for this prefix
        process.environment = environmentVariables()

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

// MARK: - Watchdog

/// Watches a Wine program `runWine` is waiting for, and says whether it is
/// still getting somewhere (`GameInstallerRunner`'s `InstallStallWatch`).
public protocol WineWatchdog: AnyObject, Sendable {
    /// The program printed a line.
    func sawOutput()
    /// Asked every few seconds while the program runs.
    func check() -> WineWatchdogVerdict
}

public enum WineWatchdogVerdict: Sendable, Equatable {
    case carryOn
    /// Carry on, and don't count this time towards the timeout: the program
    /// is waiting on the person, who may take as long as they like.
    case waitingOnPerson
    /// Stop it: no sign of progress for this long.
    case stalled(quietFor: TimeInterval)
}

// MARK: - Wine Errors

public enum WineError: LocalizedError {
    case executionFailed(exitCode: Int32)
    case terminatedBySignal(Int32)
    case timedOut(seconds: TimeInterval)
    case winetricksNotFound
    case winetricksFailed(trick: String)
    /// The program printed Wine's `nodrv_CreateWindow` error: it found no
    /// usable desktop, so it ran without a display.
    case noDisplay
    /// Its `WineWatchdog` said it had stopped getting anywhere, so it was
    /// stopped, `quietFor` after its last sign of progress.
    case stalled(quietFor: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .executionFailed(let code):
            return "Wine execution failed with exit code \(code)"
        case .terminatedBySignal(let signal):
            return "Wine was killed by \(SubprocessWatch.signalName(signal))"
        case .timedOut(let seconds):
            return "Wine did not finish within \(SubprocessWatch.duration(seconds)) and was stopped"
        case .winetricksNotFound:
            return "Winetricks not found in bundle"
        case .winetricksFailed(let trick):
            return "Failed to install winetrick: \(trick)"
        case .noDisplay:
            return "The Windows program found no display to open its windows on (Wine's nodrv_CreateWindow)"
        case .stalled(let quietFor):
            return "Wine showed no sign of progress for \(SubprocessWatch.duration(quietFor)) and was stopped"
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
