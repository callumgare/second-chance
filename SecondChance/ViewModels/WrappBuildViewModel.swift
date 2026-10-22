//
//  WrappBuildViewModel.swift
//  SecondChance
//
//  ViewModel for managing the wrapp build process

import Foundation
import SwiftUI
import Combine
import Logging

/// Builds the I/O for one wrapp build.
///
/// Production passes the standard env-var-first `WrappBuildInput`. Integration
/// tests substitute one carrying fixed paths, which is what lets a test drive
/// the real `buildFrom*` entry points without any global state.
typealias WrappBuildInputFactory = @MainActor (WrappBuildViewModel) -> WrappBuildInput

/// Main ViewModel for coordinating the wrapp build process
@MainActor
class WrappBuildViewModel: ObservableObject {
    @Published var currentState: WrappBuildState = .idle
    @Published var selectedWrappSource: WrappSource?
    /// The game holding Steam, when a Steam build failed because of it: the
    /// error screen offers to try again, and to quit it as a fallback.
    @Published var steamInUseHolder: SteamLockHolder?
    /// Quitting `steamInUseHolder` for the person is under way.
    @Published var isQuittingSteamHolder = false
    /// It was asked to quit, and didn't.
    @Published var steamHolderDidNotQuit = false
    @Published var detectedGame: GameInfo?
    /// Where the finished wrapp was saved, for Show in Finder.
    @Published var builtWrappURL: URL?
    /// What the person has to do for the build to go on, if anything: the
    /// latest `.instructions` event.
    @Published var instructions: String?
    /// The person asked to stop the build, which is winding down.
    @Published private(set) var isCancelling = false

    @Published var progress: Double = 0.0

    /// Where the success reports question is, while a build waits on it:
    /// the main window shows it in place of the build's progress.
    enum SuccessReportsQuestion {
        case asking
        /// They said yes, and are being thanked.
        case thanking
    }
    @Published private(set) var successReportsQuestion: SuccessReportsQuestion?
    private var successReportsAnswered: CheckedContinuation<Void, Never>?

    /// The failed build's report, for the error screen.
    let failureReport = FailureReportModel()

    private let diskBuilder = DiskWrappBuilder()
    private let herDownloadBuilder = HerDownloadWrappBuilder()
    private let steamBuilder = SteamWrappBuilder()
    private let cacheManager = CacheManager.shared
    private var busSubscriptionToken: EventBus<AppEvent>.Token?
    private let makeInput: WrappBuildInputFactory
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.WrappBuildViewModel")

    // Elapsed-time tracking — mirrors the original AsyncProgressReporter timer behaviour.
    // The UI only shows substep and elapsed time after 5 s so fast sub-steps don't flash.
    private var stepStartTime: Date?
    private var lastProgressState: WrappBuildState?
    private var stepTimer: Timer?
    private var shouldShowElapsed = false
    private var isBuilding = false
    /// The build under way, for `cancelBuild`.
    private var buildTask: Task<Void, Never>?

    // Development settings
    var enableCaching = false
    var stagesToRestore: Set<CacheStage> = []

    init(makeInput: @escaping WrappBuildInputFactory = { WrappBuildInput(viewModel: $0) }) {
        self.makeInput = makeInput

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
            case .instructions(let text):
                instructions = text
            case .progress(let state):
                // Error presentation is owned by the `.failed` event, which
                // carries the typed error. A `.progress(.error)` only has the
                // localized string, so handling it here would flash the error
                // screen before `.failed` routes an early cancel back to idle.
                if case .error = state { return }
                applyProgress(state)
            case .gameDetected(let info):
                detectedGame = info
                FailureReporter.setGame(info.id, source: selectedWrappSource?.rawValue, engine: info.gameEngine.rawValue)
            case .failed(let error):
                instructions = nil
                stopStepTimer()
                // A cancelled build goes back to the start once it has wound
                // down (`runBuild`), whatever error it stopped with.
                if !isCancelling { handleBuildFailure(error) }
            case .completed:
                instructions = nil
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
        LogContext.enterStage(state.displayText)

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
            // Scheduled on the main run loop, so it fires on the main thread.
            stepTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickStepTimer() }
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

    /// Start a build from `source`.
    func build(from source: WrappSource) async {
        switch source {
        case .disk: await buildFromDisk()
        case .herDownload: await buildFromHerDownload()
        case .steam: await buildFromSteam()
        }
    }

    /// Stop the build under way. Each builder cleans up after itself as it
    /// would after a failure (unmounting discs, removing the half-made app,
    /// stopping Wine and Steam), and then the welcome screen comes back.
    func cancelBuild() {
        guard let buildTask, !isCancelling else { return }
        logger.notice("The person cancelled the build")
        isCancelling = true
        buildTask.cancel()
        finishSuccessReportsQuestion()
    }

    // MARK: - Success reports question

    /// Show the success reports question, and wait until it has been
    /// answered (and a yes thanked) or the build is cancelled.
    func askAboutSuccessReports() async {
        await withCheckedContinuation { continuation in
            successReportsAnswered = continuation
            successReportsQuestion = .asking
            // The build may have been left running in the background.
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func answerSuccessReports(_ send: Bool) {
        ReportingPreferences.update { $0.successReports = send }
        logger.notice("Success reports: \(send ? "on" : "off"), as asked after the first successful build")
        if send {
            successReportsQuestion = .thanking
        } else {
            finishSuccessReportsQuestion()
        }
    }

    /// Back to the build, which carries on.
    func finishSuccessReportsQuestion() {
        successReportsQuestion = nil
        successReportsAnswered?.resume()
        successReportsAnswered = nil
    }

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
        // The source's prompts are sheets, which leave the menu bar's
        // Install commands free to start a second build.
        guard !isBuilding else { return }
        isBuilding = true
        instructions = nil
        // Its own task, so that Cancel can cancel just the build.
        let task = Task { await self.performBuild(builder) }
        buildTask = task
        await task.value
        buildTask = nil
        isBuilding = false
        if isCancelling {
            isCancelling = false
            // Too late to stop, the app was saved: say so as usual.
            if builtWrappURL == nil { reset() }
        }
    }

    private func performBuild(_ builder: WrappBuildStrategy) async {
        // A new build: none of the last one's stage carries over to it.
        LogContext.clearStage()
        lastProgressState = nil
        let input = makeInput(self)
        let loadMonitor = SystemLoadMonitor()
        loadMonitor.start()
        defer { loadMonitor.stop() }
        do {
            builtWrappURL = try await builder.build(input: input)
            currentState = .completed
            recordBuild(outcome: SuccessReport.ok)
        } catch {
            if isCancelling { return }
            if !Self.isCancellation(error) {
                let summary = FailureSummary.log(logger, what: "Building the wrapp", error: error)
                failureReport.report(FailureReport(
                    what: "Building the wrapp", error: error, game: detectedGame?.id,
                    source: selectedWrappSource?.rawValue, engine: detectedGame?.gameEngine.rawValue,
                    summary: summary
                ))
                recordBuild(outcome: ErrorChain.identifier(error))
            }
            handleBuildFailure(error)
        }
    }

    // MARK: - Helper Methods

    /// Count the build for the success reports, if the person said yes.
    private func recordBuild(outcome: String) {
        SuccessReporter.record(SuccessReport(
            event: .build, outcome: outcome, game: detectedGame?.id,
            source: selectedWrappSource?.rawValue, engine: detectedGame?.gameEngine.rawValue
        ))
    }

    /// Whether `error` is the user cancelling, which needs no summary.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        guard let buildError = error as? WrappBuildError else { return error is CancellationError }
        return buildError == .userCancelled || buildError == .userCancelledBeforeStart
    }

    /// Handle errors
    private func handleError(_ error: Error) {
        currentState = .error(error.localizedDescription)
    }

    /// Route build failures. Cancelling the initial disk-selection
    /// dialog means the user never really started — quietly return to the
    /// welcome screen. Cancelling any later prompt (disk 2, save location)
    /// abandons work already done, so it shows the error screen.
    private func handleBuildFailure(_ error: Error) {
        if case .steamInUse(let holder) = error as? WrappBuildError {
            steamInUseHolder = holder
        }
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
        builtWrappURL = nil
        progress = 0.0
        instructions = nil
        stopStepTimer()
        lastProgressState = nil
        failureReport.clear()
        FailureReporter.setGame(nil)
        steamInUseHolder = nil
        isQuittingSteamHolder = false
        steamHolderDidNotQuit = false
    }

    /// Start the Steam build again, from the error screen.
    func retrySteamBuild() {
        reset()
        selectedWrappSource = .steam
        Task { await build(from: .steam) }
    }

    /// The fallback the error screen offers: quit the game holding Steam
    /// for the person, then try again.
    func quitSteamHolderAndRetry() {
        guard let holder = steamInUseHolder, !isQuittingSteamHolder else { return }
        isQuittingSteamHolder = true
        steamHolderDidNotQuit = false
        Task {
            let gone = await Task.detached { holder.quit() }.value
            isQuittingSteamHolder = false
            if gone {
                retrySteamBuild()
            } else {
                steamHolderDidNotQuit = true
            }
        }
    }
}
