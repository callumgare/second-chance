//
//  ContentView.swift
//  SecondChance
//
//  Main content view that orchestrates the UI

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: WrappBuildViewModel
    /// The step the build last reached, so a failure can mark it.
    @State private var lastStep: InstallerStep = .source

    /// The window's fixed content size. `ReadmeScreenshot` takes the
    /// README's screenshots at it too.
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
            if let step = InstallerStep(newState) {
                lastStep = step
            }
            if case .error = newState {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }

    private var currentStep: InstallerStep {
        InstallerStep(viewModel.currentState) ?? .summary
    }

    private var failedStep: InstallerStep? {
        guard case .error = viewModel.currentState else { return nil }
        return lastStep
    }
}

#Preview {
    ContentView()
        .environmentObject(WrappBuildViewModel())
}
