//
//  WelcomeView.swift
//  SecondChance
//
//  Welcome screen with installation type selection

import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var viewModel: InstallationViewModel
    @State private var isHoveringDisk = false
    @State private var isHoveringHer = false
    @State private var isHoveringSteam = false
    @State private var showingDebugSettings = false
    
    var body: some View {
        VStack(spacing: 30) {
            // Logo and title
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                
                Text("Welcome Detective!")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Second Chance")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)
            
            // Description
            Text("Play Nancy Drew games on your Mac by creating a wrapper app from your installation source.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Spacer()
            
            // Installation options
            VStack(spacing: 20) {
                Text("Choose Your Installation Source:")
                    .font(.headline)
                
                HStack(spacing: 20) {
                    // Disk option
                    InstallationOptionCard(
                        icon: "opticaldiscdrive",
                        title: "Game Disk(s)",
                        description: "Install from original CDs",
                        isHovering: isHoveringDisk
                    )
                    .onTapGesture {
                        Task {
                            await viewModel.installFromDisk()
                        }
                    }
                    .onHover { hovering in
                        isHoveringDisk = hovering
                    }
                    
                    // Her Download option
                    InstallationOptionCard(
                        icon: "arrow.down.circle",
                        title: "Her Download",
                        description: "Windows installer from Her Interactive",
                        isHovering: isHoveringHer
                    )
                    .onTapGesture {
                        Task {
                            await viewModel.installFromHerDownload()
                        }
                    }
                    .onHover { hovering in
                        isHoveringHer = hovering
                    }
                    
                    // Steam option
                    InstallationOptionCard(
                        icon: "cloud",
                        title: "Steam",
                        description: "Install from Steam library",
                        isHovering: isHoveringSteam
                    )
                    .onTapGesture {
                        Task {
                            await viewModel.installFromSteam()
                        }
                    }
                    .onHover { hovering in
                        isHoveringSteam = hovering
                    }
                }
            }
            
            Spacer()
            
            // Footer
            HStack {
                Button(action: {
                    showingDebugSettings = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                        Text("Debug")
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Open debug settings")
                
                Spacer()
            }
            .padding(.horizontal, 20)
            
            Text("Second Chance - Bringing Nancy Drew games to modern macOS")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingDebugSettings) {
            DebugSettingsView()
        }
    }
}

struct InstallationOptionCard: View {
    let icon: String
    let title: String
    let description: String
    let isHovering: Bool
    
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: icon)
                .font(.system(size: 50))
                .foregroundStyle(isHovering ? .blue : .secondary)
            
            Text(title)
                .font(.headline)
            
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: 180, height: 180)
        .background(
            RoundedRectangle(cornerRadius: 15)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(isHovering ? 0.2 : 0.1), radius: isHovering ? 10 : 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(isHovering ? Color.blue : Color.clear, lineWidth: 2)
        )
        .scaleEffect(isHovering ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .cursor(isHovering ? .pointingHand : .arrow)
    }
}

#Preview {
    WelcomeView()
        .environmentObject(InstallationViewModel())
        .frame(width: 700, height: 500)
}
