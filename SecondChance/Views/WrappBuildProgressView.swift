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
        } else if let question = viewModel.successReportsQuestion {
            successReports(question)
        } else {
            inProgress
        }
    }

    /// Asked once, after the first build that worked. Neither answer is
    /// pushed: neither button is the default, and no key picks one.
    @ViewBuilder
    private func successReports(_ question: WrappBuildViewModel.SuccessReportsQuestion) -> some View {
        switch question {
        case .asking:
            InstallerPage(title: "Send success reports?") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("To help identify which games run correctly and which need work Second Chance can notify the developer on a successful run. Only very basic info is sent like the title of the game and macOS version. Nothing about you or your files will ever be sent.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("You can change this any time in Settings.")
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            } leading: {
                EmptyView()
            } trailing: {
                Button("Don't Send") { viewModel.answerSuccessReports(false) }
                Button("Send") { viewModel.answerSuccessReports(true) }
            }
            .accessibilityIdentifier("success-reports-question")
        case .thanking:
            InstallerPage(title: "Thank you!") {
                Text("Your success reports will help show which games work.")
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } leading: {
                EmptyView()
            } trailing: {
                Button("Continue") { viewModel.finishSuccessReportsQuestion() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var gameName: String? {
        viewModel.detectedGame.map { "Nancy Drew: \($0.title)" }
    }

    @State private var confirmingCancel = false

    private var inProgress: some View {
        InstallerPage(title: gameName.map { "Installing \($0)" } ?? "Installing…") {
            if let instructions = viewModel.instructions {
                Label {
                    Text(instructions)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.point.right.fill")
                        .foregroundStyle(.tint)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                if let progress = viewModel.currentState.progress {
                    ProgressView(value: progress, total: 1.0)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(viewModel.isCancelling ? "Stopping…" : Self.status(of: viewModel.currentState))
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

            Text("This usually takes a few minutes. You can leave it running and do something else.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        } leading: {
            EmptyView()
        } trailing: {
            Button("Cancel") {
                confirmingCancel = true
            }
            .keyboardShortcut(.cancelAction)
            .disabled(viewModel.isCancelling)
            .confirmationDialog("Stop installing the game?", isPresented: $confirmingCancel) {
                Button("Stop Installing", role: .destructive) {
                    viewModel.cancelBuild()
                }
                Button("Keep Installing", role: .cancel) {}
            } message: {
                Text("Nothing will be saved, and you can start again from the beginning.")
            }
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
        case .settingUpWrapp: return "Getting ready…"
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
