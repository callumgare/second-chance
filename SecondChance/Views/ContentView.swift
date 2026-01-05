//
//  ContentView.swift
//  SecondChance
//
//  Main content view that orchestrates the UI

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: InstallationViewModel
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            // Content
            Group {
                switch viewModel.currentState {
                case .idle, .selectingInstallationType:
                    WelcomeView()
                case .error(let message):
                    ErrorView(message: message)
                default:
                    InstallationProgressView()
                }
            }
            .padding()
        }
        .alert("Error", isPresented: $viewModel.showingError) {
            Button("OK") {
                viewModel.reset()
            }
        } message: {
            Text(viewModel.errorMessage)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(InstallationViewModel())
}
