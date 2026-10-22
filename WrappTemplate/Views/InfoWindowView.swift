//
//  InfoWindowView.swift
//  WrappTemplate
//
//  SwiftUI view for the info/warning window shown during game launch.

import SwiftUI
import Combine
import Logging

private nonisolated let infoWindowLogger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.InfoWindow")

class InfoWindowViewModel: ObservableObject {
    enum Phase {
        case warning
        case loading
        /// `explanation` is set for a game that quit unexpectedly rather than crashing.
        case error(exitCode: Int32, explanation: String?)
        /// The person quit a launch that seemed stuck, and its report is
        /// being sent (or asked about) before the wrapp quits.
        case gaveUp
    }

    @Published var phase: Phase
    @Published private(set) var stage: LoadingStage
    @Published var showSlowLoadingNote = false
    @Published var showSuspectedHang = false
    @Published var dontShowAgain = false

    let saveWarningEnabled: Bool
    let gameSlug: String
    /// The failed launch's report, for the error screen.
    let failureReport = FailureReportModel()
    var onConfirm: (() -> Void)?
    /// Where I Understand is drawn, in the hosting view's coordinates (top-left
    /// origin, as the hosting view is flipped), so
    /// WrappPuppeteer can click it through the wrapp (PuppetServer).
    var confirmButtonFrame: CGRect = .zero
    /// Set when the game could be started without Steam instead (see
    /// `GameConfig.canLaunchWithoutSteam`): offered when the launch fails, or
    /// may have.
    var onLaunchWithoutSteam: (() -> Void)?
    /// What to do about the last session's Wine, still running: offered once
    /// `.lastSessionClosing` has taken longer than usual.
    var onLastSessionChoice: ((LastSessionChoice) -> Void)?

    enum LastSessionChoice {
        case stopItAndContinue, continueAnyway, dontStart
    }

    private(set) var gameHasLoaded = false
    /// The current stage's clock, while the loading content shows.
    private var clock: LoadingClock?
    /// Checks `clock` once a second.
    private var clockTimer: Timer?
    private var quitWhenReported: AnyCancellable?

    /// Reports the launch as stuck, for `giveUpIfStuck`: the report and its
    /// sending.
    var reportStuckLaunch: (() -> (FailureReport, Task<ReportOutcome, Never>))?

    /// A newer Second Chance than the one that built this wrapp, once a
    /// failure has looked for one and found it.
    @Published var newerRelease: ReleaseVersion?
    /// The Second Chance that built this wrapp.
    let builtWith = NewerRelease.runningVersion()
    private var newerReleaseCheck: Task<Void, Never>?

    init(stage: LoadingStage, saveWarningEnabled: Bool, gameSlug: String = "nancy-drew") {
        self.stage = stage
        self.saveWarningEnabled = saveWarningEnabled
        self.gameSlug = gameSlug
        self.phase = saveWarningEnabled ? .warning : .loading
    }

    func confirm() {
        phase = .loading
        startStageTimers()
        onConfirm?()
    }

    /// Move on to `stage`, starting its clock afresh: a note or warning about
    /// the previous stage doesn't carry over.
    func setStage(_ stage: LoadingStage) {
        guard stage != self.stage else { return }
        if stage.logName != self.stage.logName {
            infoWindowLogger.debug("[Loading] Stage: \(stage.logName)")
        }
        self.stage = stage
        guard case .loading = phase else { return }
        startStageTimers()
    }

    /// Start the current stage's clock afresh: the slow note, then the
    /// possible failure, as the stage's `LoadingClock` judges them.
    func startStageTimers() {
        stopTimer()
        showSlowLoadingNote = false
        showSuspectedHang = false
        clock = LoadingClock(stage: stage)
        clock?.heavyLoad = heavyLoad != nil
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkClock() }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    /// A sign the launch is still getting somewhere. Main thread only.
    func noteProgress(_ sign: LaunchProgressSign) {
        clock?.note(sign)
    }

    /// Set while the Mac is too busy for the game to start promptly: the
    /// stage gets longer before it may count as failed.
    @Published var heavyLoad: SystemLoadReading? {
        didSet { clock?.heavyLoad = heavyLoad != nil }
    }

    private func checkClock() {
        guard let clock else { return }
        let ran = Int(Date().timeIntervalSince(clock.started))
        if !showSlowLoadingNote, clock.isSlow() {
            showSlowLoadingNote = true
            infoWindowLogger.notice("[Loading] \(stage.subject) is taking longer than usual: \(ran)s into \(stage.logName)")
        }
        // Stays up once shown, until the next stage: a stalled launch that
        // stirs again isn't proof it will finish.
        if !showSuspectedHang, clock.mayHaveFailed() {
            showSuspectedHang = true
            let quiet = Int(Date().timeIntervalSince(clock.lastProgress))
            let load = clock.heavyLoad ? " (the Mac is heavily loaded)" : ""
            infoWindowLogger.warning("[Loading] Possible launch failure: \(ran)s into \(stage.logName), no sign of progress for \(quiet)s\(load)")
            if stage != .lastSessionClosing {
                checkForNewerRelease()
            }
        }
    }

    func showError(exitCode: Int32, explanation: String? = nil) {
        stopTimer()
        phase = .error(exitCode: exitCode, explanation: explanation)
        checkForNewerRelease()
    }

    /// Look for a newer Second Chance, once: a launch that fails may be fixed
    /// in it. Only on a failure, so a launch that works asks nothing of the
    /// network.
    func checkForNewerRelease() {
        guard newerReleaseCheck == nil else { return }
        newerReleaseCheck = Task { @MainActor [weak self] in
            let newer = await NewerRelease.check()
            self?.newerRelease = newer
        }
    }

    /// Quitting while the possible-failure note is up: report the launch as
    /// stuck, then quit once the report has gone or been declined. Returns
    /// whether it did, in which case this quit should wait for that one.
    func giveUpIfStuck() -> Bool {
        guard case .loading = phase, showSuspectedHang, !gameHasLoaded,
              FailureReporter.isEnabled, let reportStuckLaunch else { return false }
        stopTimer()
        let (report, sending) = reportStuckLaunch()
        failureReport.track(report, sending: sending)
        phase = .gaveUp
        checkForNewerRelease()
        quitWhenReported = failureReport.$outcome
            .receive(on: DispatchQueue.main)
            .sink { outcome in
                // Scheduled rather than called: this runs in a main-queue job,
                // which a quit that waits for cleanup would wait on for ever.
                switch outcome {
                case .sent:
                    // Long enough to read that it was sent, rather than flash.
                    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 1)
                case .declined, .disabled:
                    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
                case .askingHowDetailed, .awaitingChoice, nil:
                    break
                }
            }
        return true
    }

    func markGameLoaded() {
        gameHasLoaded = true
        stopTimer()
    }

    func stopTimer() {
        clockTimer?.invalidate()
        clockTimer = nil
        clock = nil
    }
}

/// Laid out as an NSAlert is: the wrapp's icon on the left, then a bold
/// message, smaller informative text, and the buttons along the bottom
/// right (a checkbox, or the log buttons, bottom left).
extension InfoWindowViewModel.Phase {
    /// The error and gave-up phases, which badge the icon.
    var isFailure: Bool {
        switch self {
        case .error, .gaveUp: return true
        case .warning, .loading: return false
        }
    }
}

struct InfoWindowView: View {
    @ObservedObject var viewModel: InfoWindowViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            icon

            VStack(alignment: .leading, spacing: 10) {
                switch viewModel.phase {
                case .warning:
                    warningContent
                case .loading:
                    loadingContent
                case .error(let exitCode, let explanation):
                    errorContent(exitCode: exitCode, explanation: explanation)
                case .gaveUp:
                    gaveUpContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: Self.width)
        .fixedSize(horizontal: true, vertical: true)
        .coordinateSpace(name: Self.rootSpace)
        .onAppear {
            if case .loading = viewModel.phase {
                viewModel.startStageTimers()
            }
        }
    }

    /// Room for four buttons on one row (Show Log, Save Log…, Quit, Launch
    /// Directly), which newer versions of macOS draw wider.
    static let width: CGFloat = 520

    /// The whole view, which fills the window's hosting view: what
    /// `confirmButtonFrame` is measured in.
    static let rootSpace = "info-window"

    /// The wrapp's icon, with a caution badge once the game has failed, as
    /// a critical alert's is.
    private var icon: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .accessibilityHidden(true)
            .frame(width: 64, height: 64)
            .overlay(alignment: .bottomTrailing) {
                if viewModel.phase.isFailure {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .yellow)
                        .font(.system(size: 26))
                        .offset(x: 4, y: 4)
                }
            }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func informative(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Warning

    private var warningContent: some View {
        Group {
            message("Save your progress often")

            informative("This game was not designed to run on modern systems, so saving regularly is recommended to avoid losing progress if it crashes.")

            HStack {
                Toggle("Don't show this again", isOn: $viewModel.dontShowAgain)
                    .toggleStyle(.checkbox)
                    .font(.callout)

                Spacer()

                Button("I Understand") {
                    viewModel.confirm()
                }
                .accessibilityIdentifier("save-regularly-warning-confirm")
                .keyboardShortcut(.defaultAction)
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { viewModel.confirmButtonFrame = proxy.frame(in: .named(Self.rootSpace)) }
                        .onChange(of: proxy.frame(in: .named(Self.rootSpace))) { _, frame in viewModel.confirmButtonFrame = frame }
                })
            }
            .padding(.top, 6)
        }
    }

    // MARK: - Loading

    /// The spinner stays up for as long as the launch is still going: a
    /// launch that has definitely failed (the game or its launcher exited)
    /// shows the error content instead, so while this shows, the game may
    /// yet start.
    private var loadingContent: some View {
        Group {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                message(viewModel.stage.message)
                    .accessibilityIdentifier("loading-message")
            }

            if let detail = viewModel.stage.detail {
                informative(detail)
            }

            if let progress = viewModel.stage.progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(progress.doneKB), total: Double(progress.totalKB))
                        .accessibilityIdentifier("loading-progress")
                    if let text = viewModel.stage.progressText {
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            // On a heavily loaded Mac a long wait is expected, not a sign the
            // launch failed: say why instead.
            if viewModel.stage == .lastSessionClosing {
                if viewModel.showSuspectedHang {
                    lastSessionNote
                }
            } else if let load = viewModel.heavyLoad {
                // The busy Mac explains a slow start; the clock has already
                // given the stage longer for it, so past that it may still
                // have failed, and the player should know (and can say so).
                heavyLoadNote(load)
                if viewModel.showSuspectedHang {
                    possibleFailureNote
                }
            } else if viewModel.showSuspectedHang {
                possibleFailureNote
            } else if viewModel.showSlowLoadingNote {
                informative("This is taking longer than usual.")
            }
        }
    }

    private func caution(_ title: String) -> some View {
        Label {
            Text(title).fontWeight(.semibold)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
        .font(.callout)
    }

    private var possibleFailureNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            caution("Possible launch failure")

            informative(viewModel.stage.possibleFailureText)

            newerReleaseNote

            launchWithoutSteamNote

            buttonBar {
                failureButtons(stillTrying: true)
            }
        }
        .accessibilityIdentifier("possible-launch-failure")
    }

    /// The last session's Wine is taking longer than usual to close: what the
    /// launch's alert used to ask. It goes away by itself if Wine closes
    /// before anyone answers.
    private var lastSessionNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            caution("The game is still closing")

            informative("Part of the game from last time is still running in the background, which can stop it starting properly. "
                + "You can stop it and carry on, or keep waiting.")

            // On one row when they fit; newer macOS draws buttons wider, and
            // a row too wide would push the window's text out of it.
            ViewThatFits(in: .horizontal) {
                HStack {
                    Spacer()
                    lastSessionButtons
                }
                VStack(alignment: .trailing) {
                    lastSessionButtons
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.top, 6)
        }
        .accessibilityIdentifier("last-session-closing")
    }

    @ViewBuilder
    private var lastSessionButtons: some View {
        Button("Don't Start the Game") { viewModel.onLastSessionChoice?(.dontStart) }
            .keyboardShortcut(.cancelAction)
            .fixedSize()
        Button("Continue Anyway") { viewModel.onLastSessionChoice?(.continueAnyway) }
            .fixedSize()
        Button("Stop It and Continue") { viewModel.onLastSessionChoice?(.stopItAndContinue) }
            .keyboardShortcut(.defaultAction)
            .fixedSize()
    }

    /// The log buttons at the leading edge and `actions` at the trailing
    /// one, on one row when they fit, else with the log buttons on a row
    /// of their own above, so that no button's title is cut short.
    private func buttonBar(@ViewBuilder actions: () -> some View) -> some View {
        let logButtons = LogActionButtons(logWindowTitle: "Game Log", saveFileNamePrefix: "nancy-drew-\(viewModel.gameSlug)")
            .fixedSize()
        let actions = HStack { actions() }.fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack {
                logButtons
                Spacer()
                actions
            }
            VStack(alignment: .leading, spacing: 12) {
                logButtons
                HStack {
                    Spacer()
                    actions
                }
            }
        }
        .padding(.top, 6)
    }

    /// For a game that can run without Steam, the offer to.
    @ViewBuilder
    private var launchWithoutSteamNote: some View {
        if viewModel.onLaunchWithoutSteam != nil {
            informative("You can start the game without Steam instead. Your saves stay on this Mac either way, but this time they won't sync with Steam Cloud.")
        }
    }

    /// Quit, and for a game that can run without Steam, Launch Directly
    /// as the default. While the launch is `stillTrying` it may yet work, so
    /// Return doesn't quit it: Quit takes Escape instead.
    @ViewBuilder
    private func failureButtons(stillTrying: Bool) -> some View {
        Button("Quit") {
            NSApp.terminate(nil)
        }
        // The default only as the one way on from a launch that has failed.
        .keyboardShortcut(!stillTrying && viewModel.onLaunchWithoutSteam == nil ? .defaultAction : .cancelAction)
        if let launchWithoutSteam = viewModel.onLaunchWithoutSteam {
            Button("Launch Directly", action: launchWithoutSteam)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("launch-without-steam")
        }
    }

    private func heavyLoadNote(_ load: SystemLoadReading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            caution("Your Mac is very busy")
            informative(Self.heavyLoadMessage(load))
        }
        .accessibilityIdentifier("heavy-load-warning")
    }

    /// For players, so names the programs rather than counting cores (the
    /// log has the numbers).
    static func heavyLoadMessage(_ load: SystemLoadReading) -> String {
        let names = load.topPrograms.map(\.name)
        let who = names.isEmpty
            ? "Other programs are using most of your Mac's processing power right now."
            : "Other programs (\(names.joined(separator: ", "))) are using most of your Mac's processing power right now."
        return "\(who) The game may take several minutes to start, and may not start at all. Quitting some of them will help."
    }

    /// When a newer Second Chance is out, the suggestion that it may fix
    /// this: a wrapp never updates itself, so the game has to be set up again.
    @ViewBuilder
    private var newerReleaseNote: some View {
        if let newer = viewModel.newerRelease {
            informative(Self.newerReleaseMessage(newer, builtWith: viewModel.builtWith))
                .accessibilityIdentifier("newer-release")
        }
    }

    static func newerReleaseMessage(_ newer: ReleaseVersion, builtWith: ReleaseVersion?) -> String {
        let versions = builtWith.map { "This game was set up with version \($0.shortVersion), and version \(newer.shortVersion) is now out." }
            ?? "Version \(newer.shortVersion) is now out."
        return "A newer Second Chance may fix this. \(versions) "
            + "Update Second Chance, then use it to set up this game again."
    }

    // MARK: - Gave up

    private var gaveUpContent: some View {
        Group {
            message("\(viewModel.stage.subject) didn't start")
            informative("It was still trying to start when you quit.")
            newerReleaseNote
            FailureReportCallout(model: viewModel.failureReport)
        }
    }

    // MARK: - Error

    private func errorContent(exitCode: Int32, explanation: String?) -> some View {
        Group {
            message(explanation == nil ? "The game crashed" : "The game quit unexpectedly")

            informative(explanation ?? "It stopped suddenly while it was running (error code \(exitCode)).")

            newerReleaseNote

            FailureReportCallout(model: viewModel.failureReport)

            HiddenUntilReportAnswered(model: viewModel.failureReport) {
                launchWithoutSteamNote
            }

            buttonBar {
                HiddenUntilReportAnswered(model: viewModel.failureReport) {
                    failureButtons(stillTrying: false)
                }
            }
        }
    }
}

#Preview("Warning") {
    InfoWindowView(viewModel: InfoWindowViewModel(stage: .startingGame(title: "Stay Tuned for Danger"), saveWarningEnabled: true))
        .frame(width: InfoWindowView.width)
}

#Preview("Heavy load") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .startingGame(title: "Stay Tuned for Danger"), saveWarningEnabled: false)
        vm.heavyLoad = SystemLoadReading(
            otherCores: 7.4, fastCores: 8,
            topPrograms: [.init(name: "Google Chrome", cores: 4), .init(name: "node", cores: 2)]
        )
        return vm
    }())
    .frame(width: InfoWindowView.width)
}

#Preview("Possible launch failure, through Steam") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .steamStartingGame(title: "Curse of Blackmoor Manor"), saveWarningEnabled: false)
        vm.showSuspectedHang = true
        return vm
    }())
    .frame(width: InfoWindowView.width)
}

#Preview("Possible launch failure, can launch without Steam") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .steamStartingGame(title: "Danger on Deception Island"), saveWarningEnabled: false)
        vm.onLaunchWithoutSteam = {}
        vm.showSuspectedHang = true
        return vm
    }())
    .frame(width: InfoWindowView.width)
}

#Preview("Heavy load past the possible-failure point, can launch without Steam") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .steamStartingGame(title: "Danger on Deception Island"), saveWarningEnabled: false)
        vm.onLaunchWithoutSteam = {}
        vm.showSuspectedHang = true
        vm.heavyLoad = SystemLoadReading(
            otherCores: 7.4, fastCores: 8,
            topPrograms: [.init(name: "Google Chrome", cores: 4), .init(name: "node", cores: 2)]
        )
        return vm
    }())
    .frame(width: InfoWindowView.width)
}

#Preview("Last session still closing") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .lastSessionClosing, saveWarningEnabled: false)
        vm.showSuspectedHang = true
        return vm
    }())
    .frame(width: InfoWindowView.width)
}

#Preview("Error") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .startingGame(title: "Stay Tuned for Danger"), saveWarningEnabled: false)
        vm.phase = .error(exitCode: 1, explanation: nil)
        return vm
    }())
    .frame(width: InfoWindowView.width)
}

#Preview("Error, with a newer Second Chance out") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .startingGame(title: "Stay Tuned for Danger"), saveWarningEnabled: false)
        vm.phase = .error(exitCode: 1, explanation: nil)
        vm.newerRelease = ReleaseVersion(shortVersion: "0.9.0", build: 400)
        return vm
    }())
    .frame(width: InfoWindowView.width)
}

#Preview("Quit unexpectedly") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .startingGame(title: "The White Wolf of Icicle Creek"), saveWarningEnabled: false)
        vm.phase = .error(exitCode: 0, explanation: "The game asked for a display mode this Mac doesn't have, and quit when it couldn't have it.")
        return vm
    }())
    .frame(width: InfoWindowView.width)
}

// TEMPORARY: offscreen renders of the failure screens for review.
func renderInfoWindowShots(to dir: String) {
    _ = NSApplication.shared
    let newer = ReleaseVersion(shortVersion: "0.7.0", build: 300)
    func vm(_ stage: LoadingStage, _ setup: (InfoWindowViewModel) -> Void) -> InfoWindowViewModel {
        let vm = InfoWindowViewModel(stage: stage, saveWarningEnabled: false)
        setup(vm)
        vm.newerRelease = newer
        return vm
    }
    let shots: [(String, InfoWindowViewModel)] = [
        ("error-crashed", vm(.startingGame(title: "Stay Tuned for Danger")) { $0.phase = .error(exitCode: 1, explanation: nil) }),
        ("error-quit-unexpectedly", vm(.startingGame(title: "The White Wolf of Icicle Creek")) {
            $0.phase = .error(exitCode: 0, explanation: "The game asked for a display mode this Mac doesn't have, and quit when it couldn't have it.")
        }),
        ("possible-launch-failure", vm(.startingGame(title: "Stay Tuned for Danger")) { $0.showSuspectedHang = true }),
        ("possible-launch-failure-steam", vm(.steamStartingGame(title: "Danger on Deception Island")) {
            $0.onLaunchWithoutSteam = {}
            $0.showSuspectedHang = true
        }),
        ("gave-up", vm(.startingGame(title: "Stay Tuned for Danger")) { $0.phase = .gaveUp }),
    ]
    for appearance in ["light", "dark"] {
        for (name, model) in shots {
            let hang = model.showSuspectedHang
            let host = NSHostingView(rootView: InfoWindowView(viewModel: model).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 520, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if hang {
                model.stopTimer()
                model.showSuspectedHang = true
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                let size = host.fittingSize
                window.setContentSize(size)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(appearance).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
