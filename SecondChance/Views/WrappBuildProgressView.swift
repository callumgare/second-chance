//
//  WrappBuildProgressView.swift
//  SecondChance
//
//  Shows wrapp build progress, and the summary once it has finished

import SwiftUI

struct WrappBuildProgressView: View {
    @EnvironmentObject var viewModel: WrappBuildViewModel

    var body: some View {
        if case .completed = viewModel.currentState {
            completed
        } else {
            inProgress
        }
    }

    private var gameName: String? {
        viewModel.detectedGame.map { "Nancy Drew: \($0.title)" }
    }

    private var inProgress: some View {
        InstallerPage(title: gameName.map { "Installing \($0)" } ?? "Installing…") {
            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                if let progress = viewModel.currentState.progress {
                    ProgressView(value: progress, total: 1.0)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(Self.status(of: viewModel.currentState))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    if let elapsed = viewModel.currentState.elapsedSeconds, elapsed > 0 {
                        Text(Duration.seconds(elapsed).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
                            .monospacedDigit()
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()
        } leading: {
            EmptyView()
        } trailing: {
            Button("Continue") {}
                .disabled(true)
        }
    }

    /// What the build is doing, for the person watching: the step's
    /// current substep once it has taken a while, else the step itself.
    /// (`displayText` names the stage in logs and reports, and stays put.)
    static func status(of state: WrappBuildState) -> String {
        if let substep = state.substep, state.elapsedSeconds != nil {
            return substep.hasSuffix("…") ? substep : substep + "…"
        }
        switch state {
        case .detectingGame: return "Finding out which game it is…"
        case .settingUpWrapp: return "Setting up…"
        case .copyingInstaller: return "Copying the installer…"
        case .installingGame: return "Installing the game…"
        case .configuringWrapp: return "Configuring the game…"
        case .savingApp: return "Saving the game…"
        default: return ""
        }
    }

    private var completed: some View {
        InstallerPage(title: "Installation complete") {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
                Text("\(gameName ?? "The game") is ready to play.")
                    .font(.headline)
                Text("Open it from the folder you saved it in, like any other app.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
        } leading: {
            if let url = viewModel.builtWrappURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        } trailing: {
            Button("Done") {
                viewModel.reset()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

#Preview("Progress") {
    WrappBuildProgressView()
        .environmentObject({
            let vm = WrappBuildViewModel()
            vm.currentState = .installingGame(substep: "Running the installer", elapsedSeconds: 42)
            vm.detectedGame = GameInfo(id: "blackmoor-manor", title: "Curse of Blackmoor Manor")
            return vm
        }())
        .frame(width: 500, height: 460)
}

#Preview("Completed") {
    WrappBuildProgressView()
        .environmentObject({
            let vm = WrappBuildViewModel()
            vm.currentState = .completed
            vm.detectedGame = GameInfo(id: "blackmoor-manor", title: "Curse of Blackmoor Manor")
            vm.builtWrappURL = URL(fileURLWithPath: "/Applications/Nancy Drew.app")
            return vm
        }())
        .frame(width: 500, height: 460)
}
