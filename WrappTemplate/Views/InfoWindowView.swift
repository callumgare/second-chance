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
        case error(exitCode: Int32)
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
    var onConfirm: (() -> Void)?
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

    func showError(exitCode: Int32) {
        stopTimer()
        phase = .error(exitCode: exitCode)
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

struct InfoWindowView: View {
    @ObservedObject var viewModel: InfoWindowViewModel

    var body: some View {
        VStack(spacing: 15) {
            switch viewModel.phase {
            case .warning:
                warningContent
            case .loading:
                loadingContent
            case .error(let exitCode):
                errorContent(exitCode: exitCode)
            }
        }
        .padding(20)
        .frame(width: 450)
        .fixedSize(horizontal: true, vertical: true)
        .onAppear {
            if case .loading = viewModel.phase {
                viewModel.startStageTimers()
            }
        }
    }

    // MARK: - Warning

    private var warningContent: some View {
        VStack(spacing: 15) {
            Text("⚠️ Important: Save Your Progress Regularly!")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text("This game was not designed to run on modern systems so saving regularly is recommended to avoid losing progress in the event of a crash.")
                .font(.system(size: NSFont.systemFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            HStack {
                Toggle("Don't show this warning again", isOn: $viewModel.dontShowAgain)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("I Understand") {
                    viewModel.confirm()
                }
                .accessibilityIdentifier("save-regularly-warning-confirm")
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Loading

    /// The spinner stays up for as long as the launch is still going: a
    /// launch that has definitely failed (the game or its launcher exited)
    /// shows the error content instead, so while this shows, the game may
    /// yet start.
    private var loadingContent: some View {
        VStack(spacing: 15) {
            ProgressView()
                .controlSize(.regular)

            Text(viewModel.stage.message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("loading-message")

            if let detail = viewModel.stage.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            // On a heavily loaded Mac a long wait is expected, not a sign the
            // launch failed: say why instead.
            if let load = viewModel.heavyLoad {
                heavyLoadNote(load)
            } else if viewModel.showSuspectedHang {
                possibleFailureNote
            } else if viewModel.showSlowLoadingNote {
                Text("This is taking longer than usual. Please be patient…")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var possibleFailureNote: some View {
        VStack(spacing: 12) {
            Label("Possible Launch Failure", systemImage: "questionmark.circle")
                .font(.system(size: NSFont.systemFontSize, weight: .semibold))
                .foregroundStyle(.orange)

            Text("\(viewModel.stage.subject) is taking much longer than usual to start, and may have failed. It's still trying, so you can keep waiting — or look at the log, or quit.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            LogActionButtons(logWindowTitle: "Game Log", saveFileNamePrefix: "nancy-drew-\(viewModel.gameSlug)")

            BugReportCallout()

            failureActions
        }
        .accessibilityIdentifier("possible-launch-failure")
    }

    /// Quit, and for a game that can run without Steam, the offer to.
    @ViewBuilder
    private var failureActions: some View {
        if let launchWithoutSteam = viewModel.onLaunchWithoutSteam {
            Text("You can start the game without Steam instead. Your saves stay on this Mac either way, but this time they won't sync with Steam Cloud.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            HStack {
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                Button("Launch Without Steam", action: launchWithoutSteam)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("launch-without-steam")
            }
        } else {
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func heavyLoadNote(_ load: SystemLoadReading) -> some View {
        VStack(spacing: 6) {
            Label("Your Mac is very busy", systemImage: "gauge.with.dots.needle.100percent")
                .font(.system(size: NSFont.systemFontSize, weight: .semibold))
                .foregroundStyle(.orange)
            Text(Self.heavyLoadMessage(load))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
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

    private func errorContent(exitCode: Int32) -> some View {
        VStack(spacing: 15) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundStyle(.red)

            Text("Game Crashed")
                .font(.title2)
                .fontWeight(.bold)

            Text("The game exited unexpectedly (exit code \(exitCode)).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            LogActionButtons(logWindowTitle: "Game Log", saveFileNamePrefix: "nancy-drew-\(viewModel.gameSlug)")

            BugReportCallout()

            failureActions
        }
    }
}

#Preview("Warning") {
    InfoWindowView(viewModel: InfoWindowViewModel(stage: .startingGame(title: "Stay Tuned for Danger"), saveWarningEnabled: true))
        .frame(width: 450)
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
    .frame(width: 450)
}

#Preview("Possible launch failure, through Steam") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .steamStartingGame(title: "Curse of Blackmoor Manor"), saveWarningEnabled: false)
        vm.showSuspectedHang = true
        return vm
    }())
    .frame(width: 450)
}

#Preview("Possible launch failure, can launch without Steam") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .steamStartingGame(title: "Danger on Deception Island"), saveWarningEnabled: false)
        vm.onLaunchWithoutSteam = {}
        vm.showSuspectedHang = true
        return vm
    }())
    .frame(width: 450)
}

#Preview("Error") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(stage: .startingGame(title: "Stay Tuned for Danger"), saveWarningEnabled: false)
        vm.phase = .error(exitCode: 1)
        return vm
    }())
    .frame(width: 450)
}
