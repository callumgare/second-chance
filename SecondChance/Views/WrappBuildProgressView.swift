//
//  WrappBuildProgressView.swift
//  SecondChance
//
//  Shows wrapp build progress, and the summary once it has finished

import SwiftUI
import GameCatalog
import SecondChanceKit

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
                    Text("""
                        To help identify which games run correctly and which need work Second Chance can notify \
                        the developer on a successful run. Only very basic info is sent like the title of the game \
                        and macOS version. Nothing about you or your files will ever be sent.
                        """)
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

            if let notice = viewModel.steamSignInNotice {
                SteamSignInNoticeBox(notice: notice) {
                    viewModel.signInToSteamAfresh()
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                // A step that can measure itself (a download) fills the bar
                // as it goes; otherwise the bar shows how far through the
                // build's steps it is.
                Group {
                    if let fraction = viewModel.stepProgress?.fraction {
                        ProgressView(value: min(max(fraction, 0), 1), total: 1.0)
                    } else if let progress = viewModel.currentState.progress {
                        ProgressView(value: progress, total: 1.0)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                .accessibilityLabel("Installing \(gameName ?? "the game")")
                .accessibilityValue(viewModel.isCancelling ? "Stopping" : Self.status(of: viewModel.currentState))

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

                if let figures = viewModel.stepProgress?.text {
                    Text(figures)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Text(Self.howLong(from: viewModel.selectedWrappSource))
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

    /// How long to expect: a Steam build downloads the game, which takes as
    /// long as the connection makes it.
    static func howLong(from source: WrappSource?) -> String {
        let leave = "You can leave it running and do something else."
        if source == .steam {
            return "Steam downloads the game, so how long this takes depends on your internet connection. \(leave)"
        }
        return "This usually takes a few minutes. \(leave)"
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
                Text(Self.whereSaved(viewModel.builtWrappURL))
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
            HStack {
                Button("Done") {
                    viewModel.reset()
                }
                if let url = viewModel.builtWrappURL {
                    Button("Play Now") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        viewModel.reset()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Where the finished app was saved, by the folder's name as the Finder
    /// shows it.
    static func whereSaved(_ url: URL?) -> String {
        guard let folder = url?.deletingLastPathComponent() else {
            return "Open it from the folder you saved it in, like any other app."
        }
        let name = FileManager.default.displayName(atPath: folder.path)
        return "It's in your \(name) folder, where you can open it like any other app."
    }
}

/// Steam slow or stuck signing in (`SteamSignInNotice`): what's happening,
/// a countdown while Steam will be started again by itself, and once it's
/// stuck the offer to sign in afresh.
struct SteamSignInNoticeBox: View {
    let notice: SteamSignInNotice
    let signInAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(notice.title).fontWeight(.semibold)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(notice.detail(now: context.date))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if notice == .stuck {
                Button(SteamSignInNotice.signInAgainButton, action: signInAgain)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("steam-sign-in-notice")
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
