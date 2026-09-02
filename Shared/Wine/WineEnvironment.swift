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

/// Wine configuration and execution utilities
public struct WineEnvironment {
    let wineDir: URL
    let wineBinDir: URL
    let prefixDir: URL
    let frameworksDir: URL
    
    static let wineUsername = "crossover"
    
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
        
        return [
            "WINEPREFIX": prefixDir.path,
            "WINE": wineBinDir.appendingPathComponent("wine").path,
            "USER": WineEnvironment.wineUsername,
            "WINEDEBUG": "-all",
            "PATH": "\(wineBinDir.path):\(originalPath):/opt/local/bin:/opt/local/sbin",
            "DYLD_FALLBACK_LIBRARY_PATH": dyldFallbackLibraryPath,
            "GST_PLUGIN_PATH": frameworksDir.appendingPathComponent("GStreamer.framework/Libraries/gstreamer-1.0").path,
            "WINETRICKS_FALLBACK_LIBRARY_PATH": dyldFallbackLibraryPath,
            "WINEBOOT_HIDE_DIALOG": "1",
            "CX_ROOT": wineDir.path,
            "MVK_CONFIG_RESUME_LOST_DEVICE": "1",
            "MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE": "1",
            "WINEESYNC": "1",
            "WINEMSYNC": "1",
            "MTL_HUD_ENABLED": "0",
            "MVK_CONFIG_FAST_MATH_ENABLED": "0",
            "DOTNET_EnableWriteXorExecute": "0"
        ]
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
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            wineLogger.error("ERROR: Failed to run \(executable): \(error)")
            return -1
        }
    }
    
    /// Run a Wine program with proper environment and architecture support
    public func runWine(
        executable: String,
        arguments: [String] = []
    ) async throws {
        let winePath = wineBinDir.appendingPathComponent(executable)
        
        // Check if Wine exists
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
        
        let process = Process()
        process.executableURL = winePath
        process.arguments = arguments
        let env = environmentVariables()
        process.environment = env
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        wineLogger.notice("Attempting to execute: \(winePath.path)")
        wineLogger.notice("With arguments: \(arguments.joined(separator: " "))")
        wineLogger.notice("Checking if file exists: \(FileManager.default.fileExists(atPath: winePath.path))")
        wineLogger.notice("Checking if file is readable: \(FileManager.default.isReadableFile(atPath: winePath.path))")
        
        // Check attributes
        if let attrs = try? FileManager.default.attributesOfItem(atPath: winePath.path) {
            let perms = attrs[.posixPermissions] as? NSNumber
            wineLogger.notice("File permissions: \(String(format: "%o", perms?.uint16Value ?? 0))")
            let fileType = attrs[.type] as? FileAttributeType
            wineLogger.notice("File type: \(fileType?.rawValue ?? "unknown")")
        }
        
        // Try to read the file to see if we have access
        if let fileHandle = try? FileHandle(forReadingFrom: winePath) {
            wineLogger.notice("Successfully opened file handle")
            try? fileHandle.close()
        } else {
            wineLogger.error("WARNING: Could not open file handle")
        }
        
        // Wine is x86_64, so we need to use arch -x86_64 on Apple Silicon
        // Use /bin/sh to execute wine with proper architecture support
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
        exec "\(winePath.path)" \(arguments.map { "\"\($0)\"" }.joined(separator: " "))
        """
        
        // Execute via shell
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellScript]

        let envPrefix = env.sorted(by: { $0.key < $1.key })
            .map { k, v in "\(k)=\(v.contains(" ") ? "\"\(v)\"" : v)" }
            .joined(separator: " ")
        wineLogger.notice("Exact command: \(envPrefix) \"\(winePath.path)\" \(arguments.map { "\"\($0)\"" }.joined(separator: " "))")
        
        do {
            try process.run()
        } catch {
            wineLogger.error("ERROR: Failed to execute wine: \(error.localizedDescription)")
            wineLogger.error("Error details: \(error)")
            throw error
        }
        
        // Wait for process to complete asynchronously (don't block the main thread)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        
        // Log output
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        
        if let output = String(data: outputHandle.readDataToEndOfFile(), encoding: .utf8), !output.isEmpty {
            wineLogger.notice("Wine output: \(output)")
        }
        
        if let error = String(data: errorHandle.readDataToEndOfFile(), encoding: .utf8), !error.isEmpty {
            wineLogger.error("Wine error: \(error)")
        }
        
        if process.terminationStatus != 0 {
            throw WineError.executionFailed(exitCode: process.terminationStatus)
        }
    }
    
    /// Run a Windows executable with wine start /wait (async version using runWine)
    public func runWindowsExecutableWithStartAsync(
        exePath: String,
        arguments: [String] = []
    ) async throws {
        let args = ["start", "/wait", "/unix", exePath] + arguments
        try await runWine(executable: "wine", arguments: args)
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

        // Ask the native-fullscreen dylib bundled into Wine's Mac driver to put
        // this game's window into a real macOS fullscreen Space. Every Mac-driver
        // process loads that dylib, so it needs to be told which one is the game;
        // Wine names each child's loader copy after the .exe it runs.
        // See WrappTemplate/NativeFullscreen/native_fullscreen.m.
        var env = environmentVariables()
        env["NATIVE_MACOS_FULLSCREEN_EXE"] = exeFileName
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: exeDir)
        
        if let outputPipe = outputPipe {
            process.standardOutput = outputPipe
        }
        if let errorPipe = errorPipe {
            process.standardError = errorPipe
        }
        
        try process.run()
        return process
    }
    
    /// Check if wineserver is running for this prefix
    public func isWineserverRunning() -> Bool {
        let wineserverPath = wineBinDir.appendingPathComponent("wineserver")
        
        let process = Process()
        process.executableURL = wineserverPath
        process.arguments = ["-k0"]  // Send null signal to check if server is running
        process.environment = environmentVariables()
        
        do {
            try process.run()
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
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            wineLogger.error("Error stopping wineserver: \(error)")
            return -1
        }
    }
}

// MARK: - Wine Errors

public enum WineError: LocalizedError {
    case executionFailed(exitCode: Int32)
    case winetricksNotFound
    case winetricksFailed(trick: String)
    
    public var errorDescription: String? {
        switch self {
        case .executionFailed(let code):
            return "Wine execution failed with exit code \(code)"
        case .winetricksNotFound:
            return "Winetricks not found in bundle"
        case .winetricksFailed(let trick):
            return "Failed to install winetrick: \(trick)"
        }
    }
}
