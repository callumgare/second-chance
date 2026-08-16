//
//  InstallationContext.swift
//  SecondChance
//
//  Context for an installation operation - combines input, output, and configuration

import Foundation
import AppKit
import UniformTypeIdentifiers

/// Context for an installation operation - provides input, output, and callbacks
protocol InstallationContext: Sendable {
    // Input methods
    func getDisk1Path() async throws -> URL
    func getDisk2Path(gameInfo: GameInfo) async throws -> URL?
    func getOutputPath(gameName: String) async throws -> URL

    // Callbacks
    func onGameDetected(_ gameInfo: GameInfo) async
    func onInstallationComplete(_ wrapperPath: URL) async

    // Post-installation
    func shouldLaunchGame() async -> (Bool, [String])

    // Sandbox-specific (for interactive mode ISO mounting)
    func requestVolumeAccess(mountPoint: URL) async throws -> URL
}

// MARK: - Non-Interactive Context

/// Non-interactive context - reads from environment, outputs to terminal (and GUI if available)
class NonInteractiveContext: InstallationContext {
    private let environment: [String: String]
    private weak var viewModel: InstallationViewModel?

    init(environment: [String: String], viewModel: InstallationViewModel?) {
        self.environment = environment
        self.viewModel = viewModel
    }
    
    func getDisk1Path() async throws -> URL {
        guard let path = environment["DISK_1_PATH"] else {
            throw InstallationError.missingRequiredParameter("DISK_1_PATH")
        }
        
        let url = URL(fileURLWithPath: path)
        
        // Validate path exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw InstallationError.invalidPath("Disk 1 path does not exist: \(path)")
        }
        
        // Validate is directory or ISO
        guard isDirectory.boolValue || url.pathExtension.lowercased() == "iso" else {
            throw InstallationError.invalidPath("Disk 1 path must be a directory or ISO file")
        }
        
        return url
    }
    
    func getDisk2Path(gameInfo: GameInfo) async throws -> URL? {
        guard let path = environment["DISK_2_PATH"] else {
            if gameInfo.diskCount > 1 {
                throw InstallationError.missingRequiredParameter("DISK_2_PATH (game requires 2 disks)")
            }
            return nil
        }
        
        let url = URL(fileURLWithPath: path)
        
        // Validate path exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw InstallationError.invalidPath("Disk 2 path does not exist: \(path)")
        }
        
        // Validate is directory or ISO
        guard isDirectory.boolValue || url.pathExtension.lowercased() == "iso" else {
            throw InstallationError.invalidPath("Disk 2 path must be a directory or ISO file")
        }
        
        return url
    }
    
    func getOutputPath(gameName: String) async throws -> URL {
        guard let path = environment["OUTPUT_PATH"] else {
            throw InstallationError.missingRequiredParameter("OUTPUT_PATH")
        }
        
        let url = URL(fileURLWithPath: path)
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        
        return url
    }
    
    func onGameDetected(_ gameInfo: GameInfo) async {
        await MainActor.run {
            viewModel?.detectedGame = gameInfo
        }
    }

    func onInstallationComplete(_ wrapperPath: URL) async {}
    
    func shouldLaunchGame() async -> (Bool, [String]) {
        let shouldLaunch = environment["LAUNCH_GAME"] == "true"
        let args = parseGameArgs(environment["LAUNCH_GAME_ARGS"])
        return (shouldLaunch, args)
    }
    
    func requestVolumeAccess(mountPoint: URL) async throws -> URL {
        // Non-interactive can't prompt - just return the mount point
        return mountPoint
    }
    
    private func parseGameArgs(_ argsString: String?) -> [String] {
        guard let args = argsString else { return [] }
        
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
}

// MARK: - Interactive Context

/// In-process test seam: set disk paths before tapping the UI to bypass NSOpenPanel.
/// Production code never touches this — it stays nil and the panels show normally.
struct PreconfiguredPaths {
    static var disk1: URL?
    static var disk2: URL?
    static var outputDir: URL?
    static var isConfigured: Bool { disk1 != nil }
    static func clear() { disk1 = nil; disk2 = nil; outputDir = nil }
}

/// Interactive context - prompts with GUI, outputs to both GUI and terminal
class InteractiveContext: InstallationContext {
    private weak var viewModel: InstallationViewModel?

    init(viewModel: InstallationViewModel) {
        self.viewModel = viewModel
    }
    
    @MainActor
    func getDisk1Path() async throws -> URL {
        if let path = PreconfiguredPaths.disk1 { return path }
        guard let url = await selectDiskOrISO(message: "Select the first game disk or ISO:") else {
            // Cancelling the very first dialog means the user never started —
            // distinct from cancelling a later prompt mid-install.
            throw InstallationError.userCancelledBeforeStart
        }
        return url
    }
    
    @MainActor
    func getDisk2Path(gameInfo: GameInfo) async throws -> URL? {
        guard gameInfo.diskCount > 1 else { return nil }
        if let path = PreconfiguredPaths.disk2 { return path }
        guard let url = await selectDiskOrISO(message: "Select the second game disk or ISO:") else {
            throw InstallationError.userCancelled
        }
        return url
    }
    
    @MainActor
    func getOutputPath(gameName: String) async throws -> URL {
        if let dir = PreconfiguredPaths.outputDir { return dir }
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
            response = panel.runModal()
        }
        
        guard response == .OK, let url = panel.url else {
            throw InstallationError.userCancelled
        }
        return url
    }
    
    func onGameDetected(_ gameInfo: GameInfo) async {
        await MainActor.run {
            viewModel?.detectedGame = gameInfo
        }
    }
    
    @MainActor
    func onInstallationComplete(_ wrapperPath: URL) async {
        // Show in Finder
        NSWorkspace.shared.selectFile(wrapperPath.path, inFileViewerRootedAtPath: "")
    }
    
    func shouldLaunchGame() async -> (Bool, [String]) {
        return (false, [])  // Interactive mode doesn't auto-launch
    }
    
    @MainActor
    func requestVolumeAccess(mountPoint: URL) async throws -> URL {
        // Skip the grant-access panel when disk paths are pre-configured (test seam).
        if PreconfiguredPaths.isConfigured { return mountPoint }
        let accessPanel = NSOpenPanel()
        accessPanel.message = "Please grant access to the mounted volume to continue"
        accessPanel.prompt = "Grant Access"
        accessPanel.canChooseFiles = false
        accessPanel.canChooseDirectories = true
        accessPanel.directoryURL = mountPoint
        accessPanel.canCreateDirectories = false
        
        let response: NSApplication.ModalResponse
        if let keyWindow = NSApp.keyWindow {
            response = await accessPanel.beginSheetModal(for: keyWindow)
        } else {
            response = accessPanel.runModal()
        }
        
        guard response == .OK, let selectedURL = accessPanel.url else {
            throw NSError(domain: "ISOMount", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Access to mounted volume was denied"
            ])
        }
        return selectedURL
    }
    
    // MARK: - Helper Methods
    
    @MainActor
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
}
