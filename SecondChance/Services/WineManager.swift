//
//  WineManager.swift
//  SecondChance
//
//  Manages Wine environment and execution

import Foundation

/// Manages Wine environment setup and execution
class WineManager {
    static let shared = WineManager()
    
    private let fileManager = FileManager.default
    private let prefixCacheDir: URL
    
    private init() {
        // Set up prefix cache directory in user's Caches (persists between runs)
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecondChance/wine-prefix-cache")
        prefixCacheDir = cacheDir
        try? fileManager.createDirectory(at: prefixCacheDir, withIntermediateDirectories: true)
    }
    
    // MARK: - Wine Prefix Management
    
    /// Get the build identifier for cache invalidation
    private func getBuildIdentifier() -> String {
        #if DEBUG
        // In debug mode, use a static identifier so cache persists across builds
        return "dev"
        #else
        // In release mode, use the bundle version to invalidate cache on updates
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            return version
        }
        return "unknown"
        #endif
    }
    
    /// Get the cached Wine prefix if available and valid
    private func getCachedPrefix() -> URL? {
        let buildId = getBuildIdentifier()
        let cachedPrefixDir = prefixCacheDir.appendingPathComponent(buildId)
        let cachedPrefix = cachedPrefixDir.appendingPathComponent("prefix")
        
        // Check if cached prefix exists and is valid
        guard fileManager.fileExists(atPath: cachedPrefix.path) else {
            return nil
        }
        
        // Verify it has the expected structure
        let driveCPath = cachedPrefix.appendingPathComponent("drive_c")
        guard fileManager.fileExists(atPath: driveCPath.path) else {
            return nil
        }
        
        return cachedPrefix
    }
    
    /// Save Wine prefix to cache
    private func cachePrefix(from sourcePath: URL) {
        let buildId = getBuildIdentifier()
        let cachedPrefixDir = prefixCacheDir.appendingPathComponent(buildId)
        let cachedPrefix = cachedPrefixDir.appendingPathComponent("prefix")
        
        do {
            // Remove old cache for this build if it exists
            try? fileManager.removeItem(at: cachedPrefixDir)
            
            // Create cache directory
            try fileManager.createDirectory(at: cachedPrefixDir, withIntermediateDirectories: true)
            
            // Copy prefix to cache
            try fileManager.copyItem(at: sourcePath, to: cachedPrefix)
            
            print("✓ Cached Wine prefix for build: \(buildId)")
        } catch {
            print("⚠️ Failed to cache Wine prefix: \(error.localizedDescription)")
        }
    }
    
    /// Create a new Wine prefix at the specified path
    func createWinePrefix(at wrapperPath: URL) async throws {
        let prefixPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix")
        
        // Check if we have a cached prefix
        if let cachedPrefix = getCachedPrefix() {
            print("✓ Using cached Wine prefix (build: \(getBuildIdentifier()))")
            
            // Copy cached prefix to wrapper
            try? fileManager.removeItem(at: prefixPath)
            try fileManager.copyItem(at: cachedPrefix, to: prefixPath)
            
            return
        }
        
        print("Initializing Wine prefix (this may take 1-2 minutes)...")
        print("This will be cached for future installations.")
        
        // Start a timer to show progress
        let startTime = Date()
        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                if !Task.isCancelled {
                    let elapsed = Int(Date().timeIntervalSince(startTime))
                    print("Wine initialization running... (\(elapsed)s elapsed)")
                }
            }
        }
        
        // Run wineboot to initialize (wineboot is a Windows program, so run it through wine)
        do {
            try await runWine(
                at: wrapperPath,
                executable: "wine",
                arguments: ["wineboot", "-u"]
            )
            
            print("Wineboot completed, waiting for wineserver to finish...")
            
            // Wait for wineserver to finish
            try await waitForWineToExit(at: wrapperPath)
            
            let totalTime = Int(Date().timeIntervalSince(startTime))
            print("Wine prefix created successfully (took \(totalTime)s)")
            
            // Cache the prefix for future use
            cachePrefix(from: prefixPath)
        } catch {
            progressTask.cancel()
            throw error
        }
        
        progressTask.cancel()
    }
    
    /// Mount a directory as a drive in Wine
    func mountDirectory(
        _ sourcePath: String,
        asDrive driveLetter: String,
        type driveType: String = "hd",
        in wrapperPath: URL
    ) throws {
        let prefixPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix")
        let dosdevicesPath = prefixPath.appendingPathComponent("dosdevices")
        
        // Create symlink for drive
        let driveLink = dosdevicesPath.appendingPathComponent("\(driveLetter):")
        
        // Remove existing link if present
        try? fileManager.removeItem(at: driveLink)
        
        // Create new symlink
        try fileManager.createSymbolicLink(
            at: driveLink,
            withDestinationURL: URL(fileURLWithPath: sourcePath, relativeTo: prefixPath)
        )
    }
    
    // MARK: - Wine Execution
    
    /// Run a program with Wine
    func runWine(
        at wrapperPath: URL,
        executable: String,
        arguments: [String] = []
    ) async throws {
        let wine = WineEnvironment(appPath: wrapperPath)
        let winePath = wine.wineBinDir.appendingPathComponent(executable)
        
        // Check if Wine exists
        guard fileManager.fileExists(atPath: winePath.path) else {
            throw NSError(domain: "WineManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: """
                Wine framework not found at: \(winePath.path)
                
                To use this app, you need to bundle Wine:
                1. Download CrossOver or extract Wine from Wineskin
                2. Copy the wine folder to: SecondChance.app/Contents/SharedSupport/wine/
                3. The structure should be: SecondChance.app/Contents/SharedSupport/wine/bin/wine
                
                Or run from Xcode: copy wine to the app's built location.
                """
            ])
        }
        
        let process = Process()
        process.executableURL = winePath
        process.arguments = arguments
        process.environment = wine.environmentVariables()
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        print("Attempting to execute: \(winePath.path)")
        print("With arguments: \(arguments.joined(separator: " "))")
        print("Checking if file exists: \(fileManager.fileExists(atPath: winePath.path))")
        print("Checking if file is readable: \(fileManager.isReadableFile(atPath: winePath.path))")
        
        // Check attributes
        if let attrs = try? fileManager.attributesOfItem(atPath: winePath.path) {
            let perms = attrs[.posixPermissions] as? NSNumber
            print("File permissions: \(String(format: "%o", perms?.uint16Value ?? 0))")
            let fileType = attrs[.type] as? FileAttributeType
            print("File type: \(fileType?.rawValue ?? "unknown")")
        }
        
        // Try to read the file to see if we have access
        if let fileHandle = try? FileHandle(forReadingFrom: winePath) {
            print("Successfully opened file handle")
            try? fileHandle.close()
        } else {
            print("WARNING: Could not open file handle")
        }
        
        // Wine is x86_64, so we need to use arch -x86_64 on Apple Silicon
        // Use /bin/sh to execute wine with proper architecture support
        let shellScript = """
        export WINEPREFIX="\(process.environment?["WINEPREFIX"] ?? "")"
        export WINE="\(process.environment?["WINE"] ?? "")"
        export DYLD_FALLBACK_LIBRARY_PATH="\(process.environment?["DYLD_FALLBACK_LIBRARY_PATH"] ?? "")"
        export PATH="\(process.environment?["PATH"] ?? "")"
        export WINEDEBUG="\(process.environment?["WINEDEBUG"] ?? "")"
        export WINEBOOT_HIDE_DIALOG="\(process.environment?["WINEBOOT_HIDE_DIALOG"] ?? "")"
        export CX_ROOT="\(process.environment?["CX_ROOT"] ?? "")"
        export USER="\(process.environment?["USER"] ?? "")"
        export WINEESYNC="\(process.environment?["WINEESYNC"] ?? "")"
        export WINEMSYNC="\(process.environment?["WINEMSYNC"] ?? "")"
        exec "\(winePath.path)" \(arguments.map { "\"\($0)\"" }.joined(separator: " "))
        """
        
        // Execute via shell
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellScript]
        
        do {
            try process.run()
        } catch {
            print("ERROR: Failed to execute wine: \(error.localizedDescription)")
            print("Error details: \(error)")
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
            print("Wine output: \(output)")
        }
        
        if let error = String(data: errorHandle.readDataToEndOfFile(), encoding: .utf8), !error.isEmpty {
            print("Wine error: \(error)")
        }
        
        if process.terminationStatus != 0 {
            throw WineError.executionFailed(exitCode: process.terminationStatus)
        }
    }
    
    /// Run a Windows executable through Wine
    func runWindowsExecutable(
        at wrapperPath: URL,
        exePath: String,
        arguments: [String] = []
    ) async throws {
        let args = [exePath] + arguments
        try await runWine(at: wrapperPath, executable: "wine", arguments: args)
    }
    
    /// Run executable with wine start /wait
    func runWindowsExecutableWithStart(
        at wrapperPath: URL,
        exePath: String,
        arguments: [String] = []
    ) async throws {
        let args = ["start", "/wait", "/unix", exePath] + arguments
        try await runWine(at: wrapperPath, executable: "wine", arguments: args)
    }
    
    /// Wait for Wine server to exit
    func waitForWineToExit(at wrapperPath: URL) async throws {
        try await runWine(at: wrapperPath, executable: "wineserver", arguments: ["-w"])
    }
    
    /// Stop Wine server
    func stopWineServer(at wrapperPath: URL) throws {
        let wine = WineEnvironment(appPath: wrapperPath)
        let wineserverPath = wine.wineBinDir.appendingPathComponent("wineserver")
        
        let process = Process()
        process.executableURL = wineserverPath
        process.arguments = ["-k"]
        process.environment = wine.environmentVariables()
        
        try process.run()
        process.waitUntilExit()
    }
    
    // MARK: - Winetricks
    
    /// Install a winetrick
    func installWinetrick(_ trick: String, at wrapperPath: URL) async throws {
        let wine = WineEnvironment(appPath: wrapperPath)
        
        // Assuming winetricks is bundled or available
        let winetricksPath = wrapperPath.appendingPathComponent("Contents/Resources/winetricks")
        
        guard fileManager.fileExists(atPath: winetricksPath.path) else {
            throw WineError.winetricksNotFound
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [winetricksPath.path, trick]
        process.environment = wine.environmentVariables()
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw WineError.winetricksFailed(trick: trick)
        }
    }
}

// MARK: - Errors

enum WineError: LocalizedError {
    case executionFailed(exitCode: Int32)
    case winetricksNotFound
    case winetricksFailed(trick: String)
    
    var errorDescription: String? {
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
