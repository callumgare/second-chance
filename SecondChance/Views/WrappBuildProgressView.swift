//
//  WrappBuildProgressView.swift
//  SecondChance
//
//  Shows wrapp build progress

import SwiftUI

struct WrappBuildProgressView: View {
    @EnvironmentObject var viewModel: WrappBuildViewModel
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // Detective icon with animation
            if #available(macOS 14.0, *) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 70))
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse, isActive: viewModel.currentState != .completed)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 70))
                    .foregroundColor(.blue)
            }
            
            // Title
            if let game = viewModel.detectedGame {
                VStack(spacing: 8) {
                    Text("Installing")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    
                    Text("Nancy Drew - \(game.title)")
                        .font(.title)
                        .fontWeight(.bold)
                }
            } else {
                Text("Installing Nancy Drew Game")
                    .font(.title)
                    .fontWeight(.bold)
                    .textSelection(.enabled)
            }
            
            Spacer().frame(height: 20)
            
            // Progress details
            VStack(spacing: 15) {
                // Status text
                Text(viewModel.currentState.displayText)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                
                // Progress bar
                if let progress = viewModel.currentState.progress {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(width: 400)
                        .tint(.blue)
                    
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 400)
                }
            }
            
            // Build stages
            WrappBuildStagesView(currentState: viewModel.currentState)
                .padding(.top, 20)
            
            Spacer()
            
            // Completed actions
            if case .completed = viewModel.currentState {
                HStack(spacing: 15) {
                    Button("Done") {
                        viewModel.reset()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct WrappBuildStagesView: View {
    let currentState: WrappBuildState
    
    private let stages: [(state: WrappBuildState, label: String)] = [
        (.detectingGame(substep: nil), "Detecting Game"),
        (.settingUpWrapp(substep: nil), "Setting Up Wrapper"),
        (.copyingInstaller(substep: nil), "Copying Installer"),
        (.installingGame(substep: nil), "Installing Game"),
        (.configuringWrapp(substep: nil), "Configuring"),
        (.savingApp(substep: nil), "Saving App"),
        (.completed, "Complete")
    ]
    
    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                HStack(spacing: 5) {
                    StageIndicator(
                        isCompleted: isStageCompleted(stage.state),
                        isCurrent: isCurrentStage(stage.state)
                    )
                    
                    Text(stage.label)
                        .font(.caption)
                        .foregroundStyle(isStageCompleted(stage.state) ? .primary : .secondary)
                    
                    if index < stages.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
    
    private func isStageCompleted(_ stage: WrappBuildState) -> Bool {
        guard let currentProgress = currentState.progress,
              let stageProgress = stage.progress else {
            return false
        }
        return currentProgress >= stageProgress
    }
    
    private func isCurrentStage(_ stage: WrappBuildState) -> Bool {
        switch (currentState, stage) {
        case (.detectingGame, .detectingGame),
             (.settingUpWrapp, .settingUpWrapp),
             (.copyingInstaller, .copyingInstaller),
             (.installingGame, .installingGame),
             (.configuringWrapp, .configuringWrapp),
             (.savingApp, .savingApp),
             (.completed, .completed):
            return true
        default:
            return false
        }
    }
}

struct StageIndicator: View {
    let isCompleted: Bool
    let isCurrent: Bool
    
    var body: some View {
        Circle()
            .fill(isCompleted ? Color.green : (isCurrent ? Color.blue : Color.gray.opacity(0.3)))
            .frame(width: 12, height: 12)
            .overlay(
                Circle()
                    .stroke(isCurrent ? Color.blue : Color.clear, lineWidth: 2)
                    .frame(width: 16, height: 16)
            )
    }
}

struct ErrorView: View {
    let message: String
    @EnvironmentObject var viewModel: WrappBuildViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundStyle(.red)

            Text("Installation Error")
                .font(.title)
                .fontWeight(.bold)

            Text(message)
                .font(.title3)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .textSelection(.enabled)

            Spacer().frame(height: 12)

            LogActionButtons(logWindowTitle: "SecondChance - Installation Log")

            BugReportCallout()

            Spacer().frame(height: 8)

            Button("Start Over") {
                viewModel.reset()
            }
            .buttonStyle(.borderedProminent)
        }
        .contentShape(Rectangle())
        .allowsHitTesting(true)
    }
}

#Preview("Progress") {
    WrappBuildProgressView()
        .environmentObject({
            let vm = WrappBuildViewModel()
            vm.currentState = .installingGame(substep: nil)
            vm.progress = 0.5
            vm.detectedGame = GameInfo(id: "blackmoor-manor", title: "Curse of Blackmoor Manor")
            return vm
        }())
        .frame(width: 700, height: 500)
}

#Preview("Error") {
    ErrorView(message: "Could not find the game installer executable")
        .environmentObject(WrappBuildViewModel())
        .frame(width: 700, height: 500)
}
