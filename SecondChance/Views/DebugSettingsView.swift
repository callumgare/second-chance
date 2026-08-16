//
//  DebugSettingsView.swift
//  SecondChance
//
//  UI for debug settings

import SwiftUI

struct DebugSettingsView: View {
    @ObservedObject var settings = DebugSettings.shared
    @ObservedObject var logWindow = LogWindow.shared
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
                    Toggle("Show Unsupported Install Options", isOn: $settings.showUnsupportedInstallOptions)
                        .help("Show partially implemented install sources (Her Download, Steam) on the welcome screen.")
                } header: {
                    Text("Installation")
                        .font(.headline)
                }
                
                Section {
                    Toggle("Show Log Window", isOn: Binding(
                        get: { logWindow.isVisible },
                        set: { show in
                            if show {
                                logWindow.showLogWindow(title: "SecondChance - Installation Log")
                            } else {
                                logWindow.hideLogWindow()
                            }
                        }
                    ))
                    .help("Show or hide the floating log window.")
                    Toggle("Mirror Logs to Disk", isOn: $settings.mirrorLogsToDisk)
                        .help("Write every log entry to a file in Downloads (backfills the current log history, then appends live). The in-memory log used for Save Logs keeps only the last 50,000 entries; the mirror keeps everything.")
                } header: {
                    Text("Debugging")
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
        .frame(width: 500, height: 420)
    }
}

#Preview {
    DebugSettingsView()
}
