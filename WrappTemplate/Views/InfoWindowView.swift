//
//  InfoWindowView.swift
//  WrappTemplate
//
//  SwiftUI view for the info/warning window shown during game launch.

import SwiftUI
import Combine

class InfoWindowViewModel: ObservableObject {
    enum Phase {
        case warning
        case loading
        /// `explanation` is set for a game that quit unexpectedly rather than crashing.
        case error(exitCode: Int32, explanation: String?)
    }

    @Published var phase: Phase
    @Published private(set) var stage: LoadingStage
    @Published var showSlowLoadingNote = false
    @Published var showSuspectedHang = false
    /// Set while the Mac is too busy for the game to start promptly.
    @Published var heavyLoad: SystemLoadReading?
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

    private(set) var gameHasLoaded = false
    private var slowLoadingTimer: Timer?
    private var suspectedHangTimer: Timer?

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
        self.stage = stage
        guard case .loading = phase else { return }
        startStageTimers()
    }

    /// Start the current stage's clock: the slow note, then the possible
    /// failure, each after the stage's own delay.
    func startStageTimers() {
        stopTimer()
        showSlowLoadingNote = false
        showSuspectedHang = false
        slowLoadingTimer = Self.timer(after: stage.slowNoteAfter) { [weak self] in
            self?.showSlowLoadingNote = true
        }
        suspectedHangTimer = Self.timer(after: stage.possibleFailureAfter) { [weak self] in
            self?.showSuspectedHang = true
        }
    }

    private static func timer(after delay: TimeInterval?, _ fire: @escaping () -> Void) -> Timer? {
        guard let delay else { return nil }
        return Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            DispatchQueue.main.async(execute: fire)
        }
    }

    func showError(exitCode: Int32, explanation: String? = nil) {
        stopTimer()
        phase = .error(exitCode: exitCode, explanation: explanation)
    }

    func markGameLoaded() {
        gameHasLoaded = true
        stopTimer()
    }

    func stopTimer() {
        slowLoadingTimer?.invalidate()
        slowLoadingTimer = nil
        suspectedHangTimer?.invalidate()
        suspectedHangTimer = nil
    }
}

/// Laid out as an NSAlert is: the wrapp's icon on the left, then a bold
/// message, smaller informative text, and the buttons along the bottom
/// right (a checkbox, or the log buttons, bottom left).
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: true, vertical: true)
        .coordinateSpace(name: Self.rootSpace)
        .onAppear {
            if case .loading = viewModel.phase {
                viewModel.startStageTimers()
            }
        }
    }

    /// The whole view, which fills the window's hosting view: what
    /// `confirmButtonFrame` is measured in.
    static let rootSpace = "info-window"

    /// The wrapp's icon, with a caution badge once the game has failed, as
    /// a critical alert's is.
    private var icon: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .frame(width: 64, height: 64)
            .overlay(alignment: .bottomTrailing) {
                if case .error = viewModel.phase {
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

            // On a heavily loaded Mac a long wait is expected, not a sign the
            // launch failed: say why instead.
            if let load = viewModel.heavyLoad {
                heavyLoadNote(load)
                // Past the possible-failure point, a game that can run
                // without Steam still gets the offer: the busy Mac may be
                // why Steam is stuck, and the game alone needs far less.
                if viewModel.showSuspectedHang, viewModel.onLaunchWithoutSteam != nil {
                    launchWithoutSteamNote
                    HStack {
                        Spacer()
                        failureButtons
                    }
                    .padding(.top, 6)
                }
            } else if viewModel.showSuspectedHang {
                possibleFailureNote
            } else if viewModel.showSlowLoadingNote {
                informative("This is taking longer than usual. Please be patient…")
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

            informative("\(viewModel.stage.subject) is taking much longer than usual to start, and may have failed. It's still trying, so you can keep waiting — or look at the log, or quit.")

            launchWithoutSteamNote

            HStack {
                LogActionButtons(logWindowTitle: "Game Log", saveFileNamePrefix: "nancy-drew-\(viewModel.gameSlug)")
                Spacer()
                failureButtons
            }
            .padding(.top, 6)
        }
        .accessibilityIdentifier("possible-launch-failure")
    }

    /// For a game that can run without Steam, the offer to.
    @ViewBuilder
    private var launchWithoutSteamNote: some View {
        if viewModel.onLaunchWithoutSteam != nil {
            informative("You can start the game without Steam instead. Your saves stay on this Mac either way, but this time they won't sync with Steam Cloud.")
        }
    }

    /// Quit, and for a game that can run without Steam, Launch Without Steam
    /// as the default.
    @ViewBuilder
    private var failureButtons: some View {
        if let launchWithoutSteam = viewModel.onLaunchWithoutSteam {
            Button("Quit") {
                NSApp.terminate(nil)
            }
            Button("Launch Without Steam", action: launchWithoutSteam)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("launch-without-steam")
        } else {
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut(.defaultAction)
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

    // MARK: - Error

    private func errorContent(exitCode: Int32, explanation: String?) -> some View {
        Group {
            message(explanation == nil ? "The game crashed" : "The game quit unexpectedly")

            informative(explanation ?? "The game exited unexpectedly (exit code \(exitCode)).")

            FailureReportCallout(model: viewModel.failureReport)

            HiddenUntilReportAnswered(model: viewModel.failureReport) {
                launchWithoutSteamNote
            }

            HStack {
                LogActionButtons(logWindowTitle: "Game Log", saveFileNamePrefix: "nancy-drew-\(viewModel.gameSlug)")
                Spacer()
                HiddenUntilReportAnswered(model: viewModel.failureReport) {
                    failureButtons
                }
            }
            .padding(.top, 6)
        }
    }
}

#Preview("Warning") {
    InfoWindowView(viewModel: InfoWindowViewModel(stage: .startingGame(title: "Stay Tuned for Danger"), saveWarningEnabled: true))
        .frame(width: 480)
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
    .frame(width: 480)
}

#Preview("Possible launch failure, through Steam") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .steamStartingGame(title: "Curse of Blackmoor Manor"), saveWarningEnabled: false)
        vm.showSuspectedHang = true
        return vm
    }())
    .frame(width: 480)
}

#Preview("Possible launch failure, can launch without Steam") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .steamStartingGame(title: "Danger on Deception Island"), saveWarningEnabled: false)
        vm.onLaunchWithoutSteam = {}
        vm.showSuspectedHang = true
        return vm
    }())
    .frame(width: 480)
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
    .frame(width: 480)
}

#Preview("Error") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .startingGame(title: "Stay Tuned for Danger"), saveWarningEnabled: false)
        vm.phase = .error(exitCode: 1, explanation: nil)
        return vm
    }())
    .frame(width: 480)
}

#Preview("Quit unexpectedly") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .startingGame(title: "The White Wolf of Icicle Creek"), saveWarningEnabled: false)
        vm.phase = .error(exitCode: 0, explanation: "The game asked for a display mode this Mac doesn't have, and quit when it couldn't have it.")
        return vm
    }())
    .frame(width: 480)
}
