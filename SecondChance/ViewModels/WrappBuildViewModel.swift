//
//  WrappBuildViewModel.swift
//  SecondChance
//
//  ViewModel for managing the wrapp build process

import Foundation
import SwiftUI
import Combine
import Logging

/// Main ViewModel for coordinating the wrapp build process
@MainActor
class WrappBuildViewModel: ObservableObject {
    @Published var currentState: WrappBuildState = .idle
    @Published var selectedWrappSource: WrappSource?
    @Published var detectedGame: GameInfo?

    @Published var progress: Double = 0.0

    private let diskBuilder = DiskWrappBuilder()
    private let herDownloadBuilder = HerDownloadWrappBuilder()
    private let steamBuilder = SteamWrappBuilder()
    private let cacheManager = CacheManager.shared
    private var busSubscriptionToken: EventBus<AppEvent>.Token?
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.WrappBuildViewModel")

    // Elapsed-time tracking — mirrors the original AsyncProgressReporter timer behaviour.
    // The UI only shows substep and elapsed time after 5 s so fast sub-steps don't flash.
    private var stepStartTime: Date?
    private var lastProgressState: WrappBuildState?
    private var stepTimer: Timer?
    private var shouldShowElapsed = false
    
    // Development settings
    var enableCaching = false
    var stagesToRestore: Set<CacheStage> = []
    
    init() {
        // Configure cache manager based on settings
        cacheManager.cachingEnabled = enableCaching
        cacheManager.stagesToRestore = stagesToRestore

        // Subscribe to the app-wide bus so wrapp-build events drive our @Published properties.
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
        case .wrappBuild(let buildEvent):
            switch buildEvent {
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
                handleBuildFailure(error)
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
    private func applyProgress(_ state: WrappBuildState) {
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

    private func withElapsedSeconds(_ state: WrappBuildState, elapsed: Int?) -> WrappBuildState {
        switch state {
        case .detectingGame(let s, _):    return .detectingGame(substep: s, elapsedSeconds: elapsed)
        case .settingUpWrapp(let s, _): return .settingUpWrapp(substep: s, elapsedSeconds: elapsed)
        case .copyingInstaller(let s, _): return .copyingInstaller(substep: s, elapsedSeconds: elapsed)
        case .installingGame(let s, _):   return .installingGame(substep: s, elapsedSeconds: elapsed)
        case .configuringWrapp(let s, _): return .configuringWrapp(substep: s, elapsedSeconds: elapsed)
        case .savingApp(let s, _):        return .savingApp(substep: s, elapsedSeconds: elapsed)
        default: return state
        }
    }

    // MARK: - Build Flow
    
    /// Start a build from disk (interactive mode)
    func buildFromDisk() async {
        await runBuild(diskBuilder)
    }
    
    /// Start a build from a Her Interactive download
    func buildFromHerDownload() async {
        await runBuild(herDownloadBuilder)
    }
    
    /// Start a build from Steam
    func buildFromSteam() async {
        await runBuild(steamBuilder)
    }
    
    /// Drive any builder: build → completed, or route the failure. The bus
    /// already routed `.failed` to `handleBusEvent`; the local catch mirrors
    /// the same early-cancel rule for throws that bypassed it.
    private func runBuild(_ builder: WrappBuildStrategy) async {
        let input = WrappBuildInput(viewModel: self)
        do {
            _ = try await builder.build(input: input)
            currentState = .completed
        } catch {
            handleBuildFailure(error)
        }
    }
    
    // MARK: - Helper Methods
    
    /// Handle errors
    private func handleError(_ error: Error) {
        currentState = .error(error.localizedDescription)
    }

    /// Route build failures. Cancelling the initial disk-selection
    /// dialog means the user never really started — quietly return to the
    /// welcome screen. Cancelling any later prompt (disk 2, save location)
    /// abandons work already done, so it shows the error screen.
    private func handleBuildFailure(_ error: Error) {
        if let installError = error as? WrappBuildError, installError == WrappBuildError.userCancelledBeforeStart {
            currentState = .idle
        } else {
            handleError(error)
        }
    }
    
    /// Reset to initial state
    func reset() {
        currentState = .idle
        selectedWrappSource = nil
        detectedGame = nil
        progress = 0.0
    }
}
