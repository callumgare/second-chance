//
//  InstallationViewModel.swift
//  SecondChance
//
//  ViewModel for managing the installation process

import Foundation
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

/// Main ViewModel for coordinating the installation process
@MainActor
class InstallationViewModel: ObservableObject {
    @Published var currentState: InstallationState = .idle
    @Published var selectedInstallationType: InstallationType?
    @Published var detectedGame: GameInfo?
    @Published var showingError = false
    @Published var errorMessage = ""
    @Published var progress: Double = 0.0
    
    private let gameInstaller = GameInstaller.shared
    private let cacheManager = CacheManager.shared
    private var stateObserver: AnyCancellable?
    
    // Track ISOs mounted by SecondChance (not pre-mounted ones)
    private var selfMountedISOs: Set<URL> = []
    
    // Development settings
    var enableCaching = false
    var stagesToRestore: Set<CacheStage> = []
    
    // Non-interactive mode settings (for command-line usage)
    var nonInteractiveMode: Bool {
        ProcessInfo.processInfo.environment["NON_INTERACTIVE"] == "true"
    }
    var installationSource: String? {
        ProcessInfo.processInfo.environment["INSTALLATION_SOURCE"]
    }
    var disk1Path: String? {
        ProcessInfo.processInfo.environment["DISK_1_PATH"]
    }
    var disk2Path: String? {
        ProcessInfo.processInfo.environment["DISK_2_PATH"]
    }
    var outputPath: String? {
        ProcessInfo.processInfo.environment["OUTPUT_PATH"]
    }
    var launchGame: Bool {
        ProcessInfo.processInfo.environment["LAUNCH_GAME"] == "true"
    }
    var launchGameArgs: [String] {
        if let args = ProcessInfo.processInfo.environment["LAUNCH_GAME_ARGS"] {
            // Split by spaces, respecting quoted strings
            var result: [String] = []
            var current = ""
            var inQuotes = false
            
            for char in args {
                if char == "\"" {
                    inQuotes = !inQuotes
                } else if char == " " && !inQuotes {
                    if !current.isEmpty {
                        result.append(current)
                        current = ""
                    }
                } else {
                    current.append(char)
                }
            }
            if !current.isEmpty {
                result.append(current)
            }
            return result
        }
        return []
    }
    
    init() {
        // Configure cache manager based on settings
        cacheManager.cachingEnabled = enableCaching
        cacheManager.stagesToRestore = stagesToRestore
        
        // Auto-start if in non-interactive mode
        if nonInteractiveMode {
            guard let source = installationSource else {
                print("❌ NON-INTERACTIVE MODE: INSTALLATION_SOURCE environment variable is required")
                print("   Valid values: disk, her-download, steam")
                exit(1)
            }
            
            guard source == "disk" || source == "her-download" || source == "steam" else {
                print("❌ NON-INTERACTIVE MODE: Invalid INSTALLATION_SOURCE '\(source)'")
                print("   Valid values: disk, her-download, steam")
                exit(1)
            }
            
            print("🤖 NON-INTERACTIVE MODE: Auto-starting installation")
            print("   Source: \(source)")
            
            // Validate required parameters for each source type
            if source == "disk" {
                guard let disk1 = disk1Path else {
                    print("❌ NON-INTERACTIVE MODE: DISK_1_PATH environment variable is required for disk installation")
                    exit(1)
                }
                print("   Disk 1: \(disk1)")
                if let disk2 = disk2Path {
                    print("   Disk 2: \(disk2)")
                }
            }
            
            guard let output = outputPath else {
                print("❌ NON-INTERACTIVE MODE: OUTPUT_PATH environment variable is required")
                print("   This should be the directory where the .app will be saved")
                exit(1)
            }
            print("   Output: \(output)")
            
            // Observe state changes to auto-exit when done
            stateObserver = $currentState.sink { [weak self] state in
                self?.handleStateChange(state)
            }
            
            Task {
                await autoNonInteractiveInstall(source: source)
            }
        }
    }
    
    // MARK: - Non-Interactive Mode
    
    /// Handle state changes in non-interactive mode - exit when complete or error
    private func handleStateChange(_ state: InstallationState) {
        guard nonInteractiveMode else { return }
        
        switch state {
        case .completed:
            // Give a brief moment for final logs to flush
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("")
                print("� NON-INTERACTIVE MODE: Exiting with success")
                exit(0)
            }
            
        case .error(let message):
            // Give a brief moment for final logs to flush
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("")
                print("🤖 NON-INTERACTIVE MODE: Exiting with error")
                print("   Error: \(message)")
                exit(1)
            }
            
        default:
            break
        }
    }
    
    /// Automatically run installation in non-interactive mode
    private func autoNonInteractiveInstall(source: String) async {
        switch source {
        case "disk":
            guard let disk1 = disk1Path else {
                print("❌ NON-INTERACTIVE MODE: DISK_1_PATH is required for disk installation")
                currentState = .error("DISK_1_PATH is required")
                return
            }
            await autoNonInteractiveInstallFromDisk(disk1Path: disk1, disk2Path: disk2Path)
            
        case "her-download":
            print("❌ NON-INTERACTIVE MODE: Her Interactive download installation not yet implemented")
            currentState = .error("Her Interactive download not yet implemented in non-interactive mode")
            
        case "steam":
            print("❌ NON-INTERACTIVE MODE: Steam installation not yet implemented")
            currentState = .error("Steam installation not yet implemented in non-interactive mode")
            
        default:
            print("❌ NON-INTERACTIVE MODE: Unknown installation source '\(source)'")
            currentState = .error("Unknown installation source")
        }
    }
    
    /// Automatically run disk installation in non-interactive mode
    private func autoNonInteractiveInstallFromDisk(disk1Path: String, disk2Path: String?) async {
        let disk1URL = URL(fileURLWithPath: disk1Path)
        
        // Check if disk 1 path exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: disk1URL.path, isDirectory: &isDirectory) else {
            print("❌ NON-INTERACTIVE MODE: Disk 1 path does not exist: \(disk1Path)")
            currentState = .error("Disk 1 path does not exist")
            return
        }
        
        // Validate disk 1 is directory or ISO
        guard isDirectory.boolValue || disk1URL.pathExtension.lowercased() == "iso" else {
            print("❌ NON-INTERACTIVE MODE: Disk 1 path must be a directory or ISO file")
            currentState = .error("Disk 1 path must be a directory or ISO file")
            return
        }
        
        // Check disk 2 if provided
        var disk2URL: URL?
        if let path2 = disk2Path {
            let url2 = URL(fileURLWithPath: path2)
            guard FileManager.default.fileExists(atPath: url2.path, isDirectory: &isDirectory) else {
                print("❌ NON-INTERACTIVE MODE: Disk 2 path does not exist: \(path2)")
                currentState = .error("Disk 2 path does not exist")
                return
            }
            guard isDirectory.boolValue || url2.pathExtension.lowercased() == "iso" else {
                print("❌ NON-INTERACTIVE MODE: Disk 2 path must be a directory or ISO file")
                currentState = .error("Disk 2 path must be a directory or ISO file")
                return
            }
            disk2URL = url2
        }
        
        await installFromDiskNonInteractive(disk1: disk1URL, disk2: disk2URL)
    }
    
    /// Non-interactive version of installFromDisk - no UI prompts
    private func installFromDiskNonInteractive(disk1: URL, disk2: URL?) async {
        print("🤖 NON-INTERACTIVE MODE: Starting automated installation")
        print("   Disk 1 Source: \(disk1.path)")
        if let disk2 = disk2 {
            print("   Disk 2 Source: \(disk2.path)")
        }
        print("")
        
        var disk1Path: URL = disk1
        var disk2Path: URL? = nil
        
        do {
            // Mount disk 1 ISO if needed
            if disk1.pathExtension.lowercased() == "iso" {
                print("🤖 Checking if Disk 1 ISO is already mounted: \(disk1.lastPathComponent)")
                disk1Path = try await mountISONonInteractive(at: disk1)
            } else {
                disk1Path = disk1
            }
            
            // Detect game first (before installation)
            print("🤖 Detecting game...")
            currentState = .detectingGame(substep: nil, elapsedSeconds: nil)
            if let gameSlug = try? await GameDetector.shared.detectGame(fromDisk: disk1Path) {
                let gameInfo = GameInfoProvider.shared.gameInfo(for: gameSlug)
                detectedGame = gameInfo
                print("🤖 Detected: \(gameInfo.title)")
                
                // Check if game requires disk 2 but none was provided
                if gameInfo.diskCount > 1 && disk2 == nil {
                    let error = "Game requires 2 disks but DISK_2_PATH was not provided"
                    print("❌ NON-INTERACTIVE MODE: \(error)")
                    errorMessage = error
                    currentState = .error(error)
                    return
                }
            }
            
            // Mount disk 2 ISO if needed
            if let disk2 = disk2 {
                if disk2.pathExtension.lowercased() == "iso" {
                    print("🤖 Checking if Disk 2 ISO is already mounted: \(disk2.lastPathComponent)")
                    disk2Path = try await mountISONonInteractive(at: disk2)
                } else {
                    disk2Path = disk2
                }
            }
            
            // Run installation
            let wrapperPath = try await gameInstaller.installFromDisk(
                disk1Path: disk1Path,
                disk2Path: disk2Path,
                progressHandler: { [weak self] state in
                    Task { @MainActor in
                        guard let self = self else { return }
                        // Don't overwrite error state with progress updates
                        if case .error = self.currentState {
                            return
                        }
                        self.currentState = state
                    }
                }
            )
            
            // Auto-save wrapper
            print("🤖 Auto-saving wrapper...")
            await saveWrapperNonInteractive(wrapperPath)
            
            print("✅ NON-INTERACTIVE MODE: Installation completed!")
            currentState = .completed
            
        } catch {
            print("❌ NON-INTERACTIVE MODE: Installation failed: \(error)")
            errorMessage = error.localizedDescription
            currentState = .error(error.localizedDescription)
        }
        
        // Cleanup: unmount any ISOs that we mounted
        await unmountSelfMountedISOs()
    }
    
    /// Non-interactive version of saveWrapper - auto-saves to specified output location
    private func saveWrapperNonInteractive(_ wrapperPath: URL) async {
        guard let outputDir = outputPath else {
            print("❌ OUTPUT_PATH environment variable not set")
            currentState = .error("OUTPUT_PATH not set")
            return
        }
        
        let outputURL = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        
        let gameName = detectedGame?.title ?? "Game"
        let finalPath = outputURL.appendingPathComponent("Nancy Drew - \(gameName).app")
        
        print("")
        print("💾 Saving wrapper app...")
        print("   Destination: \(finalPath.path)")
        
        currentState = .savingApp(substep: nil, elapsedSeconds: nil)
        
        do {
            // Remove existing if present
            if FileManager.default.fileExists(atPath: finalPath.path) {
                try FileManager.default.removeItem(at: finalPath)
            }
            
            // Move wrapper
            try FileManager.default.moveItem(at: wrapperPath, to: finalPath)
            
            // Sign
            try WrapperBuilder.shared.signWrapper(at: finalPath)
            
            print("")
            print("✅ NON-INTERACTIVE MODE: Installation completed successfully!")
            print("   App saved to: \(finalPath.path)")
            
            // Launch game if requested
            if launchGame {
                print("")
                print("🚀 Launching game...")
                if !launchGameArgs.isEmpty {
                    print("   Arguments: \(launchGameArgs.joined(separator: " "))")
                }
                
                // Find the executable
                let macosDir = finalPath.appendingPathComponent("Contents/MacOS")
                if let enumerator = FileManager.default.enumerator(at: macosDir, includingPropertiesForKeys: [.isExecutableKey], options: [.skipsHiddenFiles]) {
                    for case let fileURL as URL in enumerator {
                        if fileURL.pathExtension != "dylib",
                           let resourceValues = try? fileURL.resourceValues(forKeys: [.isExecutableKey]),
                           resourceValues.isExecutable == true {
                            
                            let process = Process()
                            process.executableURL = fileURL
                            process.arguments = launchGameArgs
                            
                            do {
                                try process.run()
                                process.waitUntilExit()
                                
                                if process.terminationStatus == 0 {
                                    print("   ✓ Game exited successfully")
                                } else {
                                    print("   ⚠ Game exited with code: \(process.terminationStatus)")
                                }
                            } catch {
                                print("   ❌ Failed to launch: \(error)")
                            }
                            break
                        }
                    }
                }
            } else {
                print("   Run with: \(finalPath.path)/Contents/MacOS/GameWrapper")
            }
        } catch {
            print("❌ Save failed: \(error)")
        }
    }
    
    /// Mount an ISO file in non-interactive mode
    /// Checks if already mounted, otherwise mounts to temp location
    private func mountISONonInteractive(at isoPath: URL) async throws -> URL {
        let fileManager = FileManager.default
        
        // Check if this ISO is already mounted
        if let existingMount = try? await checkIfISOAlreadyMounted(isoPath) {
            print("   ✓ ISO already mounted at: \(existingMount.path)")
            return existingMount
        }
        
        // Mount the ISO using hdiutil
        print("   Mounting ISO...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-nobrowse", "-readonly", isoPath.path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ISOMount", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to mount ISO: \(output)"
            ])
        }
        
        // Parse hdiutil output to get mount point
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ISOMount", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to read mount output"
            ])
        }
        
        // Find the mount point in the output (last column, usually /Volumes/...)
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let parts = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if let mountPoint = parts.last, mountPoint.hasPrefix("/") {
                let mountURL = URL(fileURLWithPath: mountPoint)
                // Track that we mounted this
                selfMountedISOs.insert(mountURL)
                print("   ✓ Mounted at: \(mountPoint)")
                return mountURL
            }
        }
        
        throw NSError(domain: "ISOMount", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Failed to find mount point in hdiutil output"
        ])
    }
    
    /// Check if an ISO is already mounted and return its mount point
    private func checkIfISOAlreadyMounted(_ isoPath: URL) async throws -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        // Parse hdiutil info output to find if our ISO is mounted
        let lines = output.components(separatedBy: "\n")
        var foundImage = false
        var mountPoint: String?
        
        for line in lines {
            if line.hasPrefix("image-path") {
                foundImage = line.contains(isoPath.path)
                mountPoint = nil
            } else if foundImage && line.contains("/Volumes/") {
                // Extract mount point
                let parts = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
                for part in parts {
                    if part.hasPrefix("/Volumes/") {
                        mountPoint = part
                        break
                    }
                }
                if mountPoint != nil {
                    break
                }
            }
        }
        
        if let mp = mountPoint {
            return URL(fileURLWithPath: mp)
        }
        return nil
    }
    
    /// Unmount ISOs that were mounted by SecondChance
    private func unmountSelfMountedISOs() async {
        guard !selfMountedISOs.isEmpty else { return }
        
        print("")
        print("🧹 Unmounting ISOs mounted during installation...")
        
        for mountPoint in selfMountedISOs {
            print("   Unmounting: \(mountPoint.path)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["detach", mountPoint.path, "-quiet"]
            
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    print("   ✓ Unmounted successfully")
                } else {
                    print("   ⚠ Failed to unmount (exit code: \(process.terminationStatus))")
                }
            } catch {
                print("   ⚠ Error unmounting: \(error)")
            }
        }
        
        selfMountedISOs.removeAll()
    }
    
    // MARK: - Installation Flow
    
    /// Start installation from disk
    func installFromDisk() async {
        do {
            // Select disk 1 (folder or ISO)
            guard let disk1URL = await selectDiskOrISO(message: "Select the first game disk or ISO:") else {
                return
            }
            
            // Mount ISO if needed
            let disk1Path: URL
            var mountedDisk1: URL?
            if disk1URL.pathExtension.lowercased() == "iso" {
                currentState = .installingGame(substep: nil, elapsedSeconds: nil) // Reusing state for mounting
                disk1Path = try await mountISO(at: disk1URL)
                mountedDisk1 = disk1Path
            } else {
                disk1Path = disk1URL
            }
            
            // Detect game and disk count
            currentState = .detectingGame(substep: nil, elapsedSeconds: nil)
            let gameSlug = try await GameDetector.shared.detectGame(fromDisk: disk1Path)
            let gameInfo = GameInfoProvider.shared.gameInfo(for: gameSlug)
            detectedGame = gameInfo
            
            // Select disk 2 if needed
            var disk2Path: URL?
            var mountedDisk2: URL?
            if gameInfo.diskCount > 1 {
                guard let disk2URL = await selectDiskOrISO(message: "Select the second game disk or ISO:") else {
                    // Unmount disk 1 if we mounted it
                    if let mounted = mountedDisk1 {
                        try? await unmountISO(at: mounted)
                    }
                    currentState = .idle
                    return
                }
                
                if disk2URL.pathExtension.lowercased() == "iso" {
                    disk2Path = try await mountISO(at: disk2URL)
                    mountedDisk2 = disk2Path
                } else {
                    disk2Path = disk2URL
                }
            }
            
            // Perform installation
            let wrapperPath = try await gameInstaller.installFromDisk(
                disk1Path: disk1Path,
                disk2Path: disk2Path,
                progressHandler: { [weak self] state in
                    Task { @MainActor in
                        self?.currentState = state
                        self?.progress = state.progress ?? 0.0
                    }
                }
            )
            
            // Unmount ISOs if we mounted them
            if let mounted = mountedDisk1 {
                try? await unmountISO(at: mounted)
            }
            if let mounted = mountedDisk2 {
                try? await unmountISO(at: mounted)
            }
            
            // Save wrapper
            try await saveWrapper(at: wrapperPath, gameInfo: gameInfo)
            
            currentState = .completed
            
        } catch {
            handleError(error)
        }
    }
    
    /// Start installation from Her Interactive download
    func installFromHerDownload() async {
        do {
            // Select installer file
            guard let installerURL = await selectFile(
                message: "Select the Windows game installer:",
                allowedTypes: [UTType(filenameExtension: "exe")].compactMap { $0 }
            ) else {
                return
            }
            
            // Perform installation
            let wrapperPath = try await gameInstaller.installFromHerDownload(
                installerPath: installerURL,
                progressHandler: { [weak self] state in
                    Task { @MainActor in
                        self?.currentState = state
                        self?.progress = state.progress ?? 0.0
                    }
                }
            )
            
            // Detect game info
            if let gameSlug = try? await GameDetector.shared.detectGame(fromInstaller: installerURL) {
                detectedGame = GameInfoProvider.shared.gameInfo(for: gameSlug)
            }
            
            // Save wrapper
            try await saveWrapper(at: wrapperPath, gameInfo: detectedGame ?? .unknownGame)
            
            currentState = .completed
            
        } catch {
            handleError(error)
        }
    }
    
    /// Start installation from Steam
    func installFromSteam() async {
        do {
            currentState = .installingGame(substep: nil, elapsedSeconds: nil)
            errorMessage = "Steam installation is not fully implemented yet. This feature is coming soon!"
            showingError = true
            currentState = .idle
        } catch {
            handleError(error)
        }
    }
    
    // MARK: - Helper Methods
    
    /// Save wrapper to user-selected location
    private func saveWrapper(at wrapperPath: URL, gameInfo: GameInfo) async throws {
        let tracker = ProgressTracker()
        
        currentState = .savingApp(substep: nil, elapsedSeconds: nil)
        await tracker.start { [weak self] elapsed in
            Task { @MainActor in
                self?.currentState = .savingApp(substep: nil, elapsedSeconds: elapsed)
            }
        }
        
        // Select save location
        let panel = NSOpenPanel()
        panel.message = "Choose where to save the Nancy Drew app:"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        
        let response: NSApplication.ModalResponse
        if let keyWindow = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: keyWindow)
        } else {
            // Fallback to running as a standalone modal if no key window
            response = panel.runModal()
        }
        
        guard response == .OK, let saveDirectory = panel.url else {
            _ = await tracker.stop()
            throw InstallationError.cancelled
        }
        
        // Generate app name
        let appName = gameInfo.title != "Other" ? "Nancy Drew - \(gameInfo.title)" : "Nancy Drew"
        var destinationPath = saveDirectory.appendingPathComponent("\(appName).app")
        
        // Handle existing files
        var counter = 1
        while FileManager.default.fileExists(atPath: destinationPath.path) {
            destinationPath = saveDirectory.appendingPathComponent("\(appName) (\(counter)).app")
            counter += 1
        }
        
        // Move wrapper to destination (run on background queue)
        try await Task.detached {
            try FileManager.default.moveItem(at: wrapperPath, to: destinationPath)
        }.value
        
        // Sign the app (run on background queue)
        try await Task.detached {
            try WrapperBuilder.shared.signWrapper(at: destinationPath)
        }.value
        
        _ = await tracker.stop()
        
        // Show in Finder
        NSWorkspace.shared.selectFile(destinationPath.path, inFileViewerRootedAtPath: "")
    }
    
    /// Select a folder using file dialog
    private func selectFolder(message: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        
        let response: NSApplication.ModalResponse
        if let keyWindow = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: keyWindow)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }
    
    /// Select a disk folder or ISO file
    private func selectDiskOrISO(message: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.folder, UTType(filenameExtension: "iso")!]
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        
        let response: NSApplication.ModalResponse
        if let keyWindow = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: keyWindow)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }
    
    /// Select a file using file dialog
    private func selectFile(message: String, allowedTypes: [UTType]) async -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = allowedTypes
        
        let response: NSApplication.ModalResponse
        if let keyWindow = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: keyWindow)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }
    
    /// Mount an ISO file and return the mount point
    private func mountISO(at isoPath: URL) async throws -> URL {
        // Start accessing security-scoped resource
        let accessing = isoPath.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                isoPath.stopAccessingSecurityScopedResource()
            }
        }
        
        // Verify the ISO file exists
        guard FileManager.default.fileExists(atPath: isoPath.path) else {
            throw NSError(domain: "ISOMount", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "ISO file not found at: \(isoPath.path)"
            ])
        }
        
        // Use NSWorkspace to open the disk image - this respects sandbox
        let workspace = NSWorkspace.shared
        let fileManager = FileManager.default
        
        let mounted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            var observer: NSObjectProtocol?
            var timeoutTask: DispatchWorkItem?
            
            // Get currently mounted volumes
            let beforeMount = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
            let beforeSet = Set(beforeMount.map { $0.path })
            
            // Listen for volume mount notifications
            observer = workspace.notificationCenter.addObserver(
                forName: NSWorkspace.didMountNotification,
                object: nil,
                queue: .main
            ) { notification in
                if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    print("Volume mounted: \(volumeURL.path)")
                    
                    // Clean up observer and timeout
                    if let obs = observer {
                        workspace.notificationCenter.removeObserver(obs)
                    }
                    timeoutTask?.cancel()
                    
                    // Need to prompt user to grant access to the mounted volume due to sandbox
                    Task { @MainActor in
                        let accessPanel = NSOpenPanel()
                        accessPanel.message = "Please grant access to the mounted volume to continue"
                        accessPanel.prompt = "Grant Access"
                        accessPanel.canChooseFiles = false
                        accessPanel.canChooseDirectories = true
                        accessPanel.directoryURL = volumeURL
                        accessPanel.canCreateDirectories = false
                        
                        let response: NSApplication.ModalResponse
                        if let keyWindow = NSApp.keyWindow {
                            response = await accessPanel.beginSheetModal(for: keyWindow)
                        } else {
                            response = accessPanel.runModal()
                        }
                        
                        if response == .OK, let selectedURL = accessPanel.url {
                            continuation.resume(returning: selectedURL)
                        } else {
                            continuation.resume(throwing: NSError(domain: "ISOMount", code: 3, userInfo: [
                                NSLocalizedDescriptionKey: "Access to mounted volume was denied"
                            ]))
                        }
                    }
                }
            }
            
            // Set timeout
            timeoutTask = DispatchWorkItem {
                if let obs = observer {
                    workspace.notificationCenter.removeObserver(obs)
                }
                continuation.resume(throwing: NSError(domain: "ISOMount", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Timeout waiting for ISO to mount"
                ]))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: timeoutTask!)
            
            // Attempt to open the ISO
            let success = workspace.open(isoPath)
            if !success {
                if let obs = observer {
                    workspace.notificationCenter.removeObserver(obs)
                }
                timeoutTask?.cancel()
                continuation.resume(throwing: NSError(domain: "ISOMount", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to open ISO file"
                ]))
            }
        }
        
        return mounted
    }
    
    /// Unmount an ISO that was previously mounted
    private func unmountISO(at mountPoint: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path]
        
        try process.run()
        process.waitUntilExit()
    }
    
    /// Handle errors
    private func handleError(_ error: Error) {
        errorMessage = error.localizedDescription
        showingError = true
        currentState = .error(error.localizedDescription)
    }
    
    /// Reset to initial state
    func reset() {
        currentState = .idle
        selectedInstallationType = nil
        detectedGame = nil
        progress = 0.0
    }
}
