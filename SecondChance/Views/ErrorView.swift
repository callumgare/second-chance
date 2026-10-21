//
//  ErrorView.swift
//  SecondChance
//
//  The summary of a build that failed: why, its failure report, and the way
//  back to the start

import SwiftUI

struct ErrorView: View {
    let message: String
    @EnvironmentObject var viewModel: WrappBuildViewModel

    var body: some View {
        InstallerPage(title: "Installation failed") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("The game couldn't be installed.")
                                .font(.headline)
                            Text(message)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    FailureReportCallout(model: viewModel.failureReport)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } leading: {
            LogActionButtons(logWindowTitle: "SecondChance - Installation Log")
        } trailing: {
            HiddenUntilReportAnswered(model: viewModel.failureReport) {
                Button("Start Over") {
                    viewModel.reset()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

#Preview("Error") {
    ErrorView(message: "Could not find the game installer executable")
        .environmentObject(WrappBuildViewModel())
        .frame(width: 500, height: 460)
}
