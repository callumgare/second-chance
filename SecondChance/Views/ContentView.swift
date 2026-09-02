//
//  ContentView.swift
//  SecondChance
//
//  Main content view that orchestrates the UI

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: WrappBuildViewModel
    
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
                case .idle, .selectingWrappSource:
                    WelcomeView()
                case .error(let message):
                    ErrorView(message: message)
                default:
                    WrappBuildProgressView()
                }
            }
            .padding()
        }
        .onChange(of: viewModel.currentState) { _, newState in
            if case .error = newState {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WrappBuildViewModel())
}
