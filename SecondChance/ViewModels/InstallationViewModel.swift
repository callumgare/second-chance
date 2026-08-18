//
//  InstallationViewModel.swift
//  SecondChance
//
//  ViewModel for managing the installation process

import Foundation
import SwiftUI
import Combine
import Logging

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
    private var busSubscriptionToken: EventBus<AppEvent>.Token?
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.InstallationViewModel")

    // Elapsed-time tracking — mirrors the original AsyncProgressReporter timer behaviour.
    // The UI only shows substep and elapsed time after 5 s so fast sub-steps don't flash.
    private var stepStartTime: Date?
    private var lastProgressState: InstallationState?
    private var stepTimer: Timer?
    private var shouldShowElapsed = false
    
    // Development settings
    var enableCaching = false
    var stagesToRestore: Set<CacheStage> = []
    
    init() {
        // Configure cache manager based on settings
        cacheManager.cachingEnabled = enableCaching
        cacheManager.stagesToRestore = stagesToRestore

        // Subscribe to the app-wide bus so installation events drive our @Published properties.
        // (Headless runs are driven by CLIBuilder, which was extracted from here.)
        Task { @MainActor in
            let token = await EventBus.app.subscribe { [weak self] event in
                await self?.handleBusEvent(event)
            }
            self.busSubscriptionToken = token
        }
    }

    // MARK: - Bus Event Handling

    /// Handle bus events — drives @Published properties from typed events.
    /// Internal (not private) so unit tests can drive it directly without
    /// racing the async subscription set up in `init`.
    func handleBusEvent(_ event: AppEvent) async {
        switch event {
        case .installation(let installEvent):
            switch installEvent {
            case .progress(let state):
                // Error presentation is owned by the `.failed` event, which
                // carries the typed error. A `.progress(.error)` only has the
                // localized string, so handling it here would flash the error
                // screen before `.failed` routes an early cancel back to idle.
                if case .error = state { return }
                applyProgress(state)
            case .gameDetected(let info):
                detectedGame = info
            case .failed(let error):
                handleInstallFailure(error)
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

        logger.notice("━━━ \(state.displayText) ━━━")

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
        let input = WrappBuildInput(viewModel: self)
        
        do {
            _ = try await installationService.performInstallation(input: input)
            currentState = .completed
        } catch {
            // The bus has already routed this failure (see handleBusEvent);
            // this mirrors the same rule at the throw site.
            handleInstallFailure(error)
        }
    }
    
    /// Start installation from Her Interactive download
    func installFromHerDownload() async {
        // TODO: Implement using the unified flow (see docs/installation-flow.md §5)
        // For now, keep the legacy direct-to-installer path, but source all
        // user I/O through WrappBuildInput like the unified flow does.
        let input = WrappBuildInput(viewModel: self)

        do {
            // Select installer file (env HER_INSTALLER_PATH or NSOpenPanel)
            let installerURL = try await input.getHerInstallerPath()
            
            let installer = gameInstaller

            // Run installation in background task to avoid blocking UI
            let wrapperPath = try await Task.detached {
                try await installer.installFromHerDownload(installerPath: installerURL)
            }.value
            
            // Detect game info
            if let gameSlug = try? await GameDetector.shared.detectGame(fromInstaller: installerURL) {
                detectedGame = GameInfoProvider.shared.gameInfo(for: gameSlug)
            }
            
            // Save wrapper using unified input
            let gameName = detectedGame?.title ?? "Unknown Game"
            let outputDir = try await input.getOutputPath(gameName: gameName)
            
            currentState = .savingApp(substep: nil)
            let finalPath = try await installationService.saveWrapper(
                from: wrapperPath,
                to: outputDir,
                gameName: gameName
            )
            
            await input.onWrappBuildComplete(finalPath)
            
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

    /// Route installation failures. Cancelling the initial disk-selection
    /// dialog means the user never really started — quietly return to the
    /// welcome screen. Cancelling any later prompt (disk 2, save location)
    /// abandons work already done, so it shows the error screen.
    private func handleInstallFailure(_ error: Error) {
        if let installError = error as? InstallationError, installError == InstallationError.userCancelledBeforeStart {
            currentState = .idle
        } else {
            handleError(error)
        }
    }
    
    /// Reset to initial state
    func reset() {
        currentState = .idle
        selectedInstallationType = nil
        detectedGame = nil
        progress = 0.0
    }
}
