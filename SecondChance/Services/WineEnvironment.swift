//
//  WineEnvironment.swift
//  Shared Wine environment and execution logic
//
//  Used by both SecondChance app and GameWrapper runtime

import Foundation

/// Wine configuration and execution utilities
public struct WineEnvironment {
    let wineDir: URL
    let wineBinDir: URL
    let prefixDir: URL
    let frameworksDir: URL
    
    static let wineUsername = "crossover"
    
    public init(appPath: URL) {
        self.wineDir = appPath.appendingPathComponent("Contents/SharedSupport/wine")
        self.wineBinDir = wineDir.appendingPathComponent("bin")
        self.prefixDir = appPath.appendingPathComponent("Contents/SharedSupport/prefix")
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
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            print("ERROR: Failed to run \(executable): \(error)")
            return -1
        }
    }
}
