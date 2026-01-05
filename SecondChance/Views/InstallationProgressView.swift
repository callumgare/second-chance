//
//  InstallationProgressView.swift
//  SecondChance
//
//  Shows installation progress

import SwiftUI

struct InstallationProgressView: View {
    @EnvironmentObject var viewModel: InstallationViewModel
    
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
            
            // Installation stages
            InstallationStagesView(currentState: viewModel.currentState)
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

struct InstallationStagesView: View {
    let currentState: InstallationState
    
    private let stages: [(state: InstallationState, label: String)] = [
        (.detectingGame(substep: nil, elapsedSeconds: nil), "Detecting Game"),
        (.settingUpWrapper(substep: nil, elapsedSeconds: nil), "Setting Up Wrapper"),
        (.copyingInstaller(substep: nil, elapsedSeconds: nil), "Copying Installer"),
        (.installingGame(substep: nil, elapsedSeconds: nil), "Installing Game"),
        (.configuringWrapper(substep: nil, elapsedSeconds: nil), "Configuring"),
        (.savingApp(substep: nil, elapsedSeconds: nil), "Saving App"),
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
    
    private func isStageCompleted(_ stage: InstallationState) -> Bool {
        guard let currentProgress = currentState.progress,
              let stageProgress = stage.progress else {
            return false
        }
        return currentProgress >= stageProgress
    }
    
    private func isCurrentStage(_ stage: InstallationState) -> Bool {
        switch (currentState, stage) {
        case (.detectingGame, .detectingGame),
             (.settingUpWrapper, .settingUpWrapper),
             (.copyingInstaller, .copyingInstaller),
             (.installingGame, .installingGame),
             (.configuringWrapper, .configuringWrapper),
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
    @EnvironmentObject var viewModel: InstallationViewModel
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundStyle(.red)
            
            Text("Installation Error")
                .font(.title)
                .fontWeight(.bold)
            
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .textSelection(.enabled)
            
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
    InstallationProgressView()
        .environmentObject({
            let vm = InstallationViewModel()
            vm.currentState = .installingGame(substep: nil, elapsedSeconds: nil)
            vm.progress = 0.5
            vm.detectedGame = GameInfo(id: "blackmoor-manor", title: "Curse of Blackmoor Manor")
            return vm
        }())
        .frame(width: 700, height: 500)
}

#Preview("Error") {
    ErrorView(message: "Could not find the game installer executable")
        .environmentObject(InstallationViewModel())
        .frame(width: 700, height: 500)
}
