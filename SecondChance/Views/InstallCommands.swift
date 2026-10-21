//
//  InstallCommands.swift
//  SecondChance
//
//  The File menu's ways to start a build, the same as the welcome screen's.

import SwiftUI

struct InstallCommands: Commands {
    @ObservedObject var viewModel: WrappBuildViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Group {
                Button("Install from Game Discs…") { start(.disk) }
                    .keyboardShortcut("o")
                Button("Install from Steam…") { start(.steam) }
                Button("Install from Her Download…") { start(.herDownload) }
            }
            .disabled(InstallerStep(viewModel.currentState) != .source)
        }
    }

    private func start(_ source: WrappSource) {
        Task { await viewModel.build(from: source) }
    }
}
