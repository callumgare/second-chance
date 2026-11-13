//
//  WrappBuildViewModel.swift
//  SecondChance
//
//  ViewModel for managing the wrapp build process

import Foundation
import SwiftUI
import Observation
import Logging
import SecondChanceKit
import SecondChanceReporting
import GameCatalog

/// Builds the I/O for one wrapp build.
///
/// Production passes the standard env-var-first `WrappBuildInput`. Integration
/// tests substitute one carrying fixed paths, which is what lets a test drive
/// the real `buildFrom*` entry points without any global state.
typealias WrappBuildInputFactory = @MainActor (WrappBuildViewModel) -> WrappBuildInput

/// Main ViewModel for coordinating the wrapp build process
@MainActor
@Observable
class WrappBuildViewModel {
    var currentState: WrappBuildState = .idle {
        didSet {
            if let step = InstallerStep(currentState) { lastStep = step }
            onStateChangeForTesting?(currentState)
        }
    }
    /// Hears every state the window would render, in order (a test's
    /// stand-in for the publisher an ObservableObject had).
    @ObservationIgnored var onStateChangeForTesting: ((WrappBuildState) -> Void)?
    /// The step the build last reached, so a failure can mark it. Kept here
    /// rather than in the window, which may be closed and opened again.
    private(set) var lastStep: InstallerStep = .source
    var selectedWrappSource: WrappSource?
    /// The game holding Steam, when a Steam build failed because of it: the
    /// error screen offers to try again, and to quit it as a fallback.
    var steamInUseHolder: SteamLockHolder?
    /// Quitting `steamInUseHolder` for the person is under way.
    var isQuittingSteamHolder = false
    /// It was asked to quit, and didn't.
    var steamHolderDidNotQuit = false
    /// Whether the welcome screen lists the sources not offered yet (free
    /// games): a double-click on the icon above the steps shows them.
    var revealsHiddenSources = false
    /// The disc or download the last build was started from, so Try Again
    /// can use it again rather than asking for it.
    @ObservationIgnored var chosenInstaller: URL?
    /// Set by Try Again for the next build's input to take
    /// (`WrappBuildInput.takeRetryInstaller`).
    @ObservationIgnored var retryInstaller: URL?
    /// Steam kept getting stuck signing in, so Try Again signs out of Steam
    /// first, in case the saved sign-in is what it's stuck on.
    var steamRetrySignsOut = false
    /// Steam is slow or stuck signing in, as the progress screen says.
    var steamSignInNotice: SteamSignInNotice?
    /// The person chose to sign in to Steam afresh, from the notice that it's
    /// stuck; the build takes it (`WrappBuildInput.takeSteamSignInAfreshRequest`).
    @ObservationIgnored var steamSignInAfreshRequested = false
    var detectedGame: GameInfo?
    /// Where the finished wrapp was saved, for Show in Finder.
    var builtWrappURL: URL?
    /// What the last build failed with, for a headless run's exit
    /// (`CLIBuilder`). Nil once a build succeeds, or starts.
    @ObservationIgnored private(set) var lastBuildError: Error?
    /// What the person has to do for the build to go on, if anything: the
    /// latest `.instructions` event.
    var instructions: String?
    /// The person asked to stop the build, which is winding down.
    private(set) var isCancelling = false

    /// How far the current step has got, when the build can measure it
    /// (`WrappBuildEvent.stepProgress`). Cleared at each new step.
    var stepProgress: StepProgress?

    /// Where the success reports question is, while a build waits on it:
    /// the main window shows it in place of the build's progress.
    enum SuccessReportsQuestion {
        case asking
        /// They said yes, and are being thanked.
        case thanking
    }
    private(set) var successReportsQuestion: SuccessReportsQuestion?
    @ObservationIgnored private var successReportsAnswered: CheckedContinuation<Void, Never>?

    /// A question the build asks part way through, which the main window
    /// shows as a page of its own, in place of the build's progress: which
    /// game to get from a store, what to do about a disc it doesn't
    /// recognise, putting in disc 2, and the rest (`WrappBuildInput`).
    struct BuildQuestion {
        /// One of a list to pick from.
        struct Choice {
            let title: String
            /// What picking it means, beneath it, if it needs saying.
            var detail: String?
        }
        /// A button along the bottom.
        struct Action {
            enum Role {
                /// The way on: takes Return, and a double-clicked choice.
                case primary
                /// Takes Escape.
                case cancel
                /// Loses something (a game that was just installed).
                case destructive
                case other
            }
            let title: String
            var role: Role = .other
        }
        let title: String
        let detail: String
        /// What the list of choices is, for VoiceOver: "Games".
        var choicesLabel = ""
        /// A list to pick from, the first picked to start with; none for a
        /// question its buttons answer alone.
        var choices: [Choice] = []
        let actions: [Action]
        /// What the build is waiting for meanwhile, shown with a spinner: a
        /// question something else can answer (disc 2 going in).
        var waiting: String?
        /// The sidebar's step while it's asked, when not the build's own.
        var step: InstallerStep?
        /// Bring Second Chance to the front, as the person has just been in
        /// another app's window (a store's sign-in); otherwise the Dock
        /// icon bounces if it's in the background.
        var comesToFront = false
    }
    /// The button a question was answered with (its index in `actions`),
    /// and the choice picked then, if it has any.
    struct BuildAnswer {
        let action: Int
        let choice: Int?
    }
    /// Set only by `ask`, and by `UIStateCatalog` to picture it.
    var question: BuildQuestion?
    @ObservationIgnored private var questionAnswered: CheckedContinuation<BuildAnswer?, Never>?

    /// The failed build's report, for the error screen.
    let failureReport = FailureReportModel()

    private let diskBuilder: DiskWrappBuilder
    private let downloadBuilder: DownloadWrappBuilder
    private let herDownloadBuilder: HerDownloadWrappBuilder
    private let steamBuilder: SteamWrappBuilder
    private let bigFishBuilder: BigFishWrappBuilder
    /// Where this view model's builds report, and where it follows them.
    let bus: EventBus<AppEvent>
    @ObservationIgnored private var busSubscriptionToken: EventBus<AppEvent>.Token?
    /// Done once the view model hears its bus: `init` subscribes in a task, so a test that publishes waits on this.
    @ObservationIgnored private(set) var subscribed: Task<Void, Never>?
    private let makeInput: WrappBuildInputFactory
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.WrappBuildViewModel")

    // Elapsed-time tracking — mirrors the original AsyncProgressReporter timer behaviour.
    // The UI only shows substep and elapsed time after 5 s so fast sub-steps don't flash.
    @ObservationIgnored private var stepStartTime: Date?
    @ObservationIgnored private var lastProgressState: WrappBuildState?
    @ObservationIgnored private var stepTimer: Task<Void, Never>?
    @ObservationIgnored private var shouldShowElapsed = false
    @ObservationIgnored private var isBuilding = false
    /// The build under way, for `cancelBuild`.
    @ObservationIgnored private var buildTask: Task<Void, Never>?

    /// `bus` is `EventBus.app` for the app's window. A test gives each build
    /// a bus of its own, so builds running side by side don't hear each
    /// other's events.
    init(
        makeInput: @escaping WrappBuildInputFactory = { WrappBuildInput(viewModel: $0) },
        bus: EventBus<AppEvent> = .app
    ) {
        self.makeInput = makeInput
        self.bus = bus
        // The helper and installer runner report on the bus too, so each
        // build has its own rather than the `.app`-bound `.shared` ones.
        let helper = WrappBuildHelper(bus: bus)
        let installerRunner = GameInstallerRunner(bus: bus)
        diskBuilder = DiskWrappBuilder(helper: helper, installerRunner: installerRunner, bus: bus)
        herDownloadBuilder = HerDownloadWrappBuilder(helper: helper, installerRunner: installerRunner, bus: bus)
        steamBuilder = SteamWrappBuilder(helper: helper, installerRunner: installerRunner, bus: bus)
        bigFishBuilder = BigFishWrappBuilder(helper: helper, installerRunner: installerRunner, bus: bus)
        downloadBuilder = DownloadWrappBuilder(helper: helper, bus: bus)

        // Subscribe to the build's bus so wrapp-build events drive the observed properties.
        // (A headless run is this view model too: CLIBuilder starts its build.)
        subscribed = Task { @MainActor in
            let token = await bus.subscribe { [weak self] event in
                await self?.handleBusEvent(event)
            }
            self.busSubscriptionToken = token
        }
    }

    // MARK: - Bus Event Handling

    /// Handle bus events — drives the observed properties from typed events.
    /// Internal (not private) so unit tests can drive it directly without
    /// racing the async subscription set up in `init`.
    func handleBusEvent(_ event: AppEvent) async {
        switch event {
        case .wrappBuild(let buildEvent):
            switch buildEvent {
            case .instructions(let text):
                instructions = text
            case .stepProgress(let measured):
                stepProgress = measured
            case .steamSignInNotice(let notice):
                steamSignInNotice = notice
            case .progress(let state):
                // Error presentation is owned by the `.failed` event, which
                // carries the typed error. A `.progress(.error)` only has the
                // localized string, so handling it here would flash the error
                // screen before `.failed` routes an early cancel back to idle.
                if case .error = state { return }
                applyProgress(state)
            case .gameDetected(let info):
                detectedGame = info
                FailureReporter.setGame(info.id, source: selectedWrappSource?.rawValue, engine: info.composition.engineTag)
            case .failed(let error):
                instructions = nil
                steamSignInNotice = nil
                stopStepTimer()
                // A cancelled build goes back to the start once it has wound
                // down (`runBuild`), whatever error it stopped with.
                guard !isCancelling else { break }
                // The report's pictures are of the step that failed, not
                // the error screen about to replace it.
                _ = await screenshotsBeforeError()
                if !isCancelling { handleBuildFailure(error) }
            case .completed(let wrappPath):
                instructions = nil
                steamSignInNotice = nil
                // With the screen, not once the builder returns: it may still
                // be tidying up (unmounting discs), and without the app's
                // place the screen has no Show in Finder or Play Now.
                builtWrappURL = wrappPath
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
        let previous = lastProgressState

        // The substep too: the screen hides it for the first 5 s, but it's
        // what says how far a step got (Steam's "Connecting to Steam").
        let substep = state.substep.map { " - \($0)" } ?? ""
        logger.notice("━━━ \(state.displayText)\(state.elapsedSeconds == nil ? substep : "") ━━━")
        LogContext.enterStage(state.displayText)

        lastProgressState = state
        stepProgress = nil

        // A new substep of the step under way shows at once once the step
        // has shown its own: the 5 s are the step's, not each substep's, or
        // the screen would fall back to the step's name between them.
        if let previous, previous.baseText == state.baseText, let startTime = stepStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            currentState = withElapsedSeconds(state, elapsed: shouldShowElapsed ? Int(elapsed) : nil)
            return
        }

        stepStartTime = Date()
        shouldShowElapsed = false
        stopStepTimer()

        // Initially show state without elapsed time (substep hidden until 5 s)
        currentState = withElapsedSeconds(state, elapsed: nil)

        // Start the timer unless the state doesn't need one
        switch state {
        case .idle, .completed, .error: break
        default:
            // On the main actor, as this class is: every second until stopped.
            stepTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self?.tickStepTimer()
                }
            }
        }
    }

    private func stopStepTimer() {
        stepTimer?.cancel()
        stepTimer = nil
    }

    /// Called every second by the step timer — reveals substep + increments elapsed.
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
        case .disk: await runBuild(diskBuilder, from: source)
        case .herDownload: await runBuild(herDownloadBuilder, from: source)
        case .steam: await runBuild(steamBuilder, from: source)
        case .bigFish: await runBuild(bigFishBuilder, from: source)
        case .download: await runBuild(downloadBuilder, from: source)
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
        answerQuestion(nil)
    }

    /// The person cancelled a question that ends the build, which winds down
    /// as a cancelled build does: "Stopping…" while it stops Steam or Big
    /// Fish and removes the half-made app, rather than the step it was on,
    /// and then the welcome screen.
    func windDownAfterCancelledQuestion() {
        guard buildTask != nil, !isCancelling else { return }
        logger.notice("The person cancelled a question, so the build is stopping")
        isCancelling = true
    }

    // MARK: - Success reports question

    /// Show the success reports question, and wait until it has been
    /// answered (and a yes thanked) or the build is cancelled.
    func askAboutSuccessReports() async {
        await withCheckedContinuation { continuation in
            // Never two builds waiting on one question: the first would
            // otherwise wait for good.
            successReportsAnswered?.resume()
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

    // MARK: - Build questions

    /// Show `question`, and wait for its answer: nil when it was withdrawn
    /// (`withdrawQuestion`) or the build cancelled.
    func ask(_ question: BuildQuestion) async -> BuildAnswer? {
        await withCheckedContinuation { continuation in
            questionAnswered?.resume(returning: nil)
            questionAnswered = continuation
            self.question = question
            if question.comesToFront {
                // The store's window, active as they signed in, would stay in
                // front of the question otherwise. The plain activate() is
                // only a request since macOS 14, which that window can keep.
                NSApp.installerWindow?.orderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            } else {
                NSApp.askForAttention()
            }
        }
    }

    func answerQuestion(_ answer: BuildAnswer?) {
        question = nil
        questionAnswered?.resume(returning: answer)
        questionAnswered = nil
    }

    /// Take the question away unanswered, as something else has answered
    /// it (disc 2 went in).
    func withdrawQuestion() {
        answerQuestion(nil)
    }

    /// Drive any builder: build → completed, or route the failure. The bus
    /// already routed `.failed` to `handleBusEvent`; the local catch mirrors
    /// the same early-cancel rule for throws that bypassed it.
    private func runBuild(_ builder: WrappBuildStrategy, from source: WrappSource) async {
        // The source's prompts are sheets, which leave the menu bar's
        // Install commands free to start a second build.
        guard !isBuilding else { return }
        isBuilding = true
        // What the progress screen's hints and every report of this build
        // say it was built from.
        selectedWrappSource = source
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
        // The build's own part of the log, so its entries can be told from
        // another build's running alongside it. One the caller bound is kept,
        // which is how a test knows which entries are its build's.
        await LogContext.$build.withValue(LogContext.build ?? BuildLogContext()) {
            await performBuildLogged(builder)
        }
    }

    private func performBuildLogged(_ builder: WrappBuildStrategy) async {
        // A new build: none of the last one's stage carries over to it.
        LogContext.clearStage()
        failureScreenshots = nil
        lastProgressState = nil
        lastBuildError = nil
        let input = makeInput(self)
        let loadMonitor = SystemLoadMonitor()
        loadMonitor.start()
        defer { loadMonitor.stop() }
        do {
            try await input.ensureRosetta(bus: bus)
            builtWrappURL = try await builder.build(input: input)
            currentState = .completed
            recordBuild(outcome: SuccessReport.ok)
        } catch {
            lastBuildError = error
            if isCancelling { return }
            if !Self.isCancellation(error) {
                let summary = FailureSummary.log(logger, what: "Building the wrapp", error: error)
                var report = FailureReport(
                    what: "Building the wrapp", error: error, game: detectedGame?.id,
                    source: selectedWrappSource?.rawValue, engine: detectedGame?.composition.engineTag,
                    summary: summary
                )
                report.screenshots = await screenshotsBeforeError()
                failureReport.report(report)
                recordBuild(outcome: ErrorChain.identifier(error))
            }
            handleBuildFailure(error)
        }
    }

    // MARK: - Helper Methods

    /// The windows as the build failed, taken once for the failure's report
    /// by whichever comes first — the bus's `.failed`, or the build's own
    /// catch — and awaited by both before the error screen shows.
    private var failureScreenshots: Task<ReportScreenshots?, Never>?

    private func screenshotsBeforeError() async -> ReportScreenshots? {
        if failureScreenshots == nil {
            failureScreenshots = Task { await ReportScreenshots.capture() }
        }
        return await failureScreenshots?.value
    }

    /// Count the build for the success reports, if the person said yes.
    private func recordBuild(outcome: String) {
        SuccessReporter.record(SuccessReport(
            event: .build, outcome: outcome, game: detectedGame?.id,
            source: selectedWrappSource?.rawValue, engine: detectedGame?.composition.engineTag
        ))
    }

    /// Whether `error` is the user cancelling, which needs no summary.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        guard let buildError = error as? WrappBuildError else { return error is CancellationError }
        return buildError == .userCancelled || buildError == .userCancelledBeforeStart
    }

    /// Route build failures. Cancelling the initial disk-selection
    /// dialog means the user never really started — quietly return to the
    /// welcome screen. Cancelling any later prompt (disk 2, save location)
    /// abandons work already done, so it shows the error screen.
    private func handleBuildFailure(_ error: Error) {
        let buildError = error as? WrappBuildError
        if case .steamInUse(let holder) = buildError {
            steamInUseHolder = holder
        }
        steamRetrySignsOut = buildError == .steamStoppedResponding
        if buildError == WrappBuildError.userCancelledBeforeStart {
            currentState = .idle
        } else {
            // Plain words only: what went wrong in detail is in the log.
            currentState = .error(WrappBuildError(error).playerMessage)
        }
    }

    /// Reset to initial state
    func reset() {
        currentState = .idle
        selectedWrappSource = nil
        detectedGame = nil
        builtWrappURL = nil
        instructions = nil
        stepProgress = nil
        chosenInstaller = nil
        stopStepTimer()
        lastProgressState = nil
        failureReport.clear()
        FailureReporter.setGame(nil)
        steamInUseHolder = nil
        isQuittingSteamHolder = false
        steamHolderDidNotQuit = false
        steamRetrySignsOut = false
        steamSignInNotice = nil
        steamSignInAfreshRequested = false
    }

    /// Sign in to Steam afresh, from the progress screen's notice that it's
    /// stuck signing in: the build signs out and starts Steam again.
    func signInToSteamAfresh() {
        logger.notice("The person chose to sign in to Steam afresh")
        steamSignInAfreshRequested = true
        steamSignInNotice = nil
    }

    /// Start the build again from the error screen, from the same source:
    /// the same disc or download when it's still there, and for Steam,
    /// signed out first when it kept getting stuck signing in.
    func retryBuild() {
        guard let source = selectedWrappSource else { return }
        let signOut = source == .steam && steamRetrySignsOut
        let installer = chosenInstaller
        reset()
        if signOut {
            logger.notice("Trying the Steam build again, signed out of Steam, as it kept getting stuck signing in")
            do {
                try SteamSessionStore().signOut()
            } catch {
                logger.error("Couldn't sign out of Steam before trying again: \(error)")
            }
        } else {
            logger.notice("Trying the build again, from \(source.rawValue)")
        }
        retryInstaller = installer
        Task { await build(from: source) }
    }

    /// The fallback the error screen offers: quit the game holding Steam
    /// for the person, then try again.
    func quitSteamHolderAndRetry() {
        guard let holder = steamInUseHolder, !isQuittingSteamHolder else { return }
        isQuittingSteamHolder = true
        steamHolderDidNotQuit = false
        Task {
            let gone = await holder.quit()
            isQuittingSteamHolder = false
            if gone {
                retryBuild()
            } else {
                steamHolderDidNotQuit = true
            }
        }
    }
}
