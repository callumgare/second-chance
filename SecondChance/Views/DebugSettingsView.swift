//
//  DebugSettingsView.swift
//  SecondChance
//
//  UI for debug settings

import SwiftUI

struct DebugSettingsView: View {
    @ObservedObject var settings = DebugSettings.shared
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("Debug Settings")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            
            Divider()
            
            // Settings list
            Form {
                Section {
                    Toggle("Skip Installer Execution", isOn: $settings.skipInstaller)
                        .help("When enabled, game files are copied but the installer is not run. Useful for testing wrapper setup without waiting for installation.")
                } header: {
                    Text("Installation")
                        .font(.headline)
                }
                
                Section {
                    HStack {
                        Spacer()
                        Button("Reset to Defaults") {
                            settings.resetToDefaults()
                        }
                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
            
            Spacer()
        }
        .frame(width: 500, height: 300)
    }
}

#Preview {
    DebugSettingsView()
}
