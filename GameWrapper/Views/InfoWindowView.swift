//
//  InfoWindowView.swift
//  GameWrapper
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
    @Published var message: String
    @Published var showSlowLoadingNote = false
    @Published var showSuspectedHang = false
    @Published var dontShowAgain = false

    let saveWarningEnabled: Bool
    let gameSlug: String
    var onConfirm: (() -> Void)?

    private(set) var gameHasLoaded = false
    private var slowLoadingTimer: Timer?
    private var suspectedHangTimer: Timer?

    init(message: String, saveWarningEnabled: Bool, gameSlug: String = "nancy-drew") {
        self.message = message
        self.saveWarningEnabled = saveWarningEnabled
        self.gameSlug = gameSlug
        self.phase = saveWarningEnabled ? .warning : .loading
    }

    func confirm() {
        phase = .loading
        startSlowLoadingTimer()
        onConfirm?()
    }

    func startSlowLoadingTimer() {
        slowLoadingTimer?.invalidate()
        slowLoadingTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.gameHasLoaded else { return }
                self.showSlowLoadingNote = true
                self.startSuspectedHangTimer()
            }
        }
    }

    private func startSuspectedHangTimer() {
        suspectedHangTimer?.invalidate()
        suspectedHangTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.gameHasLoaded else { return }
                self.showSuspectedHang = true
            }
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
                viewModel.startSlowLoadingTimer()
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

    private var loadingContent: some View {
        VStack(spacing: 15) {
            if viewModel.showSuspectedHang {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)

                Text("Possible Launch Failure")
                    .font(.title3)
                    .fontWeight(.bold)

                Text("The game is taking suspiciously long to start. It may have failed to launch.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                LogActionButtons(logWindowTitle: "Game Log", saveFileNamePrefix: "nancy-drew-\(viewModel.gameSlug)")

                BugReportCallout()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView()
                    .controlSize(.regular)

                Text(viewModel.message)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                if viewModel.showSlowLoadingNote {
                    Text("This is taking longer than expected. Please be patient...")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
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

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview("Warning") {
    InfoWindowView(viewModel: InfoWindowViewModel(message: "Loading Stay Tuned for Danger...", saveWarningEnabled: true))
        .frame(width: 450)
}

#Preview("Error") {
    InfoWindowView(viewModel: {
        let vm = InfoWindowViewModel(message: "", saveWarningEnabled: false)
        vm.phase = .error(exitCode: 1)
        return vm
    }())
    .frame(width: 450)
}
