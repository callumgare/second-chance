//
//  ContentView.swift
//  SecondChance
//
//  Main content view that orchestrates the UI

import SwiftUI
import SecondChanceKit

struct ContentView: View {
    @Environment(WrappBuildViewModel.self) var viewModel

    /// The window's fixed content size, which `UIStateCatalog` draws its
    /// states at too.
    static let size = CGSize(width: 680, height: 460)

    var body: some View {
        HStack(spacing: 0) {
            InstallerSidebar(current: currentStep, failed: failedStep)

            Divider()

            Group {
                switch viewModel.currentState {
                case .idle, .selectingWrappSource, .selectingSource:
                    WelcomeView()
                case .error(let message):
                    ErrorView(message: message)
                default:
                    WrappBuildProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onChange(of: viewModel.currentState) { _, newState in
            switch newState {
            case .error(let message):
                // Not under test: a failed build's window (`BuildWindow`)
                // must not take the front from a game another test is
                // launching.
                if !TestHost.isRunning { NSApp.activate() }
                AccessibilityNotification.Announcement("Installation failed. \(message)").post()
            case .completed:
                AccessibilityNotification.Announcement("Installation complete. The game is ready to play.").post()
            default:
                break
            }
        }
        .onChange(of: viewModel.instructions) { _, instructions in
            // What the person has to do now, said as soon as it appears.
            if let instructions {
                AccessibilityNotification.Announcement(instructions).post()
            }
        }
    }

    private var currentStep: InstallerStep {
        InstallerStep(viewModel.currentState) ?? .summary
    }

    private var failedStep: InstallerStep? {
        guard case .error = viewModel.currentState else { return nil }
        return viewModel.lastStep
    }
}

#Preview {
    ContentView()
        .environment(WrappBuildViewModel())
}
