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
import os

/// Main ViewModel for coordinating the installation process
@MainActor
class InstallationViewModel: ObservableObject {
    @Published var currentState: InstallationState = .idle
    @Published var selectedInstallationType: InstallationType?
    @Published var detectedGame: GameInfo?

    @Published var progress: Double = 0.0

    private let installationService = InstallationService()
    private let gameInstaller = GameInstaller.shared
    private let cacheManager = CacheManager.shared
    private var stateObserver: AnyCancellable?
    private var busSubscriptionToken: EventBus<AppEvent>.Token?
    private let logger = Logger(subsystem: "com.secondchance", category: "InstallationViewModel")

    // Elapsed-time tracking — mirrors the original AsyncProgressReporter timer behaviour.
    // The UI only shows substep and elapsed time after 5 s so fast sub-steps don't flash.
    private var stepStartTime: Date?
    private var lastProgressState: InstallationState?
    private var stepTimer: Timer?
    private var shouldShowElapsed = false
    
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
    var clearWineCache: Bool {
        CommandLine.arguments.contains("--clear-wine-cache")
    }
    
    init() {
        // Clear Wine cache if requested
        if clearWineCache {
            logger.notice("Clearing Wine prefix cache...")
            do {
                try WineManager.shared.clearCache()
            } catch {
                logger.fault("Failed to clear Wine prefix cache: \(error.localizedDescription, privacy: .public)")
                exit(1)
            }
        }
        
        // Configure cache manager based on settings
        cacheManager.cachingEnabled = enableCaching
        cacheManager.stagesToRestore = stagesToRestore

        // Subscribe to the app-wide bus so installation events drive our @Published properties.
        Task { @MainActor in
            let token = await EventBus.app.subscribe { [weak self] event in
                await self?.handleBusEvent(event)
            }
            self.busSubscriptionToken = token
        }

        // Auto-start if in non-interactive mode
        if nonInteractiveMode {
            guard let source = installationSource else {
                logger.fault("NON-INTERACTIVE MODE: INSTALLATION_SOURCE environment variable is required (disk, her-download, steam)")
                exit(1)
            }

            guard source == "disk" || source == "her-download" || source == "steam" else {
                logger.fault("NON-INTERACTIVE MODE: Invalid INSTALLATION_SOURCE '\(source, privacy: .public)' (disk, her-download, steam)")
                exit(1)
            }

            logger.notice("NON-INTERACTIVE MODE: Auto-starting installation — source: \(source, privacy: .public)")

            // Validate required parameters for each source type
            if source == "disk" {
                guard let disk1 = disk1Path else {
                    logger.fault("NON-INTERACTIVE MODE: DISK_1_PATH environment variable is required for disk installation")
                    exit(1)
                }
                logger.notice("Disk 1: \(disk1, privacy: .public)")
                if let disk2 = disk2Path {
                    logger.notice("Disk 2: \(disk2, privacy: .public)")
                }
            }

            guard let output = outputPath else {
                logger.fault("NON-INTERACTIVE MODE: OUTPUT_PATH environment variable is required (directory where .app will be saved)")
                exit(1)
            }
            logger.notice("Output: \(output, privacy: .public)")
            
            // Observe state changes to auto-exit when done
            stateObserver = $currentState.sink { [weak self] state in
                self?.handleStateChange(state)
            }
            
            // Run installation in detached task so it doesn't block app termination
            Task.detached { [weak self] in
                await self?.autoNonInteractiveInstall(source: source)
            }
        }
    }
    
    // MARK: - Non-Interactive Mode

    /// Handle bus events — drives @Published properties from typed events.
    private func handleBusEvent(_ event: AppEvent) async {
        switch event {
        case .installation(let installEvent):
            switch installEvent {
            case .progress(let state):
                applyProgress(state)
            case .gameDetected(let info):
                detectedGame = info
            case .failed(let error):
                handleError(error)
                stopStepTimer()
            case .completed:
                currentState = .completed
                stopStepTimer()
            default:
                break
            }
        default:
            break
        }
    }

    /// Handle state changes in non-interactive mode - exit when complete
    private func handleStateChange(_ state: InstallationState) {
        guard nonInteractiveMode else { return }

        switch state {
        case .completed:
            logger.notice("NON-INTERACTIVE MODE: Exiting with success")
            fflush(stdout)
            AutomationBridge.shared.stop()
            _exit(0)
        default:
            break
        }
    }
    
    /// Automatically run installation in non-interactive mode
    private func autoNonInteractiveInstall(source: String) async {
        let context = NonInteractiveContext(
            environment: ProcessInfo.processInfo.environment,
            viewModel: self
        )
        
        do {
            switch source {
            case "disk":
                _ = try await installationService.performInstallation(context: context)
                await MainActor.run {
                    currentState = .completed
                }
                
            case "her-download":
                logger.fault("NON-INTERACTIVE MODE: Her Interactive download installation not yet implemented")
                throw NSError(domain: "Installation", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Her Interactive download not yet implemented in non-interactive mode"
                ])

            case "steam":
                logger.fault("NON-INTERACTIVE MODE: Steam installation not yet implemented")
                throw NSError(domain: "Installation", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Steam installation not yet implemented in non-interactive mode"
                ])

            default:
                logger.fault("NON-INTERACTIVE MODE: Unknown installation source '\(source, privacy: .public)'")
                throw NSError(domain: "Installation", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Unknown installation source"
                ])
            }
        } catch {
            await MainActor.run {
                currentState = .error(error.localizedDescription)
            }
            logger.fault("NON-INTERACTIVE MODE: Exiting with error — \(error.localizedDescription, privacy: .public)")
            fflush(stdout)
            fflush(stderr)
            _exit(1)
        }
    }
    
    // MARK: - Elapsed-time tracking

    /// Apply a progress state with the elapsed-time delay logic from the
    /// original AsyncProgressReporter: the UI sees no substep or elapsed time
    /// for the first 5 s; after that a repeating timer drives the counter.
    private func applyProgress(_ state: InstallationState) {
        if case .error = currentState { return }

        let isNewStep = lastProgressState.map {
            $0.displayText != state.displayText || $0.substep != state.substep
        } ?? true

        guard isNewStep else { return }

        logger.notice("\n━━━ \(state.displayText, privacy: .public) ━━━")

        stepStartTime = Date()
        shouldShowElapsed = false
        lastProgressState = state
        stopStepTimer()

        // Initially show state without elapsed time (substep hidden until 5 s)
        currentState = withElapsedSeconds(state, elapsed: nil)
        progress = state.progress ?? 0.0

        // Start the timer unless the state doesn't need one
        switch state {
        case .idle, .completed, .error: break
        default:
            stepTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.tickStepTimer()
            }
        }
    }

    private func stopStepTimer() {
        stepTimer?.invalidate()
        stepTimer = nil
    }

    /// Called every 5 s by the step timer — reveals substep + increments elapsed.
    private func tickStepTimer() {
        guard let state = lastProgressState, let startTime = stepStartTime else { return }
        if case .error = currentState { stopStepTimer(); return }

        let elapsed = Date().timeIntervalSince(startTime)
        if !shouldShowElapsed, elapsed >= 5.0 { shouldShowElapsed = true }

        if shouldShowElapsed {
            currentState = withElapsedSeconds(state, elapsed: Int(elapsed))
        }
    }

    private func withElapsedSeconds(_ state: InstallationState, elapsed: Int?) -> InstallationState {
        switch state {
        case .detectingGame(let s, _):    return .detectingGame(substep: s, elapsedSeconds: elapsed)
        case .settingUpWrapper(let s, _): return .settingUpWrapper(substep: s, elapsedSeconds: elapsed)
        case .copyingInstaller(let s, _): return .copyingInstaller(substep: s, elapsedSeconds: elapsed)
        case .installingGame(let s, _):   return .installingGame(substep: s, elapsedSeconds: elapsed)
        case .configuringWrapper(let s, _): return .configuringWrapper(substep: s, elapsedSeconds: elapsed)
        case .savingApp(let s, _):        return .savingApp(substep: s, elapsedSeconds: elapsed)
        default: return state
        }
    }

    // MARK: - Installation Flow
    
    /// Start installation from disk (interactive mode)
    func installFromDisk() async {
        let context = InteractiveContext(viewModel: self)
        
        do {
            _ = try await installationService.performInstallation(context: context)
            currentState = .completed
        } catch {
            // Check if it's a cancellation error
            if let installError = error as? InstallationError, installError == InstallationError.cancelled {
                // User cancelled - just reset
                currentState = .idle
            } else {
                handleError(error)
            }
        }
    }
    
    /// Start installation from Her Interactive download
    func installFromHerDownload() async {
        // TODO: Implement using new unified flow with HerDownloadContext
        // For now, keep old implementation
        do {
            // Select installer file
            let panel = NSOpenPanel()
            panel.message = "Select the Windows game installer:"
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [UTType(filenameExtension: "exe")].compactMap { $0 }
            
            let response: NSApplication.ModalResponse
            if let keyWindow = NSApp.keyWindow {
                response = await panel.beginSheetModal(for: keyWindow)
            } else {
                response = panel.runModal()
            }
            
            guard response == .OK, let installerURL = panel.url else {
                return
            }
            
            let installer = gameInstaller

            // Run installation in background task to avoid blocking UI
            let wrapperPath = try await Task.detached {
                try await installer.installFromHerDownload(installerPath: installerURL)
            }.value
            
            // Detect game info
            if let gameSlug = try? await GameDetector.shared.detectGame(fromInstaller: installerURL) {
                detectedGame = GameInfoProvider.shared.gameInfo(for: gameSlug)
            }
            
            // Save wrapper using interactive context
            let context = InteractiveContext(viewModel: self)
            let gameName = detectedGame?.title ?? "Unknown Game"
            let outputDir = try await context.getOutputPath(gameName: gameName)
            
            currentState = .savingApp(substep: nil)
            let finalPath = try await installationService.saveWrapper(
                from: wrapperPath,
                to: outputDir,
                gameName: gameName
            )
            
            await context.onInstallationComplete(finalPath)
            
            currentState = .completed
            
        } catch {
            handleError(error)
        }
    }
    
    /// Start installation from Steam
    func installFromSteam() async {
        do {
            currentState = .error("Steam installation is not fully implemented yet. This feature is coming soon!")
        } catch {
            handleError(error)
        }
    }
    
    // MARK: - Helper Methods
    
    /// Handle errors
    private func handleError(_ error: Error) {
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
