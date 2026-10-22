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
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    // The callout in the message's column, so their text lines up.
                    VStack(alignment: .leading, spacing: 16) {
                        Text(message)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)

                        if let holder = viewModel.steamInUseHolder, holder.canQuit, let name = holder.name {
                            SteamHolderFallback(name: name)
                        }

                        FailureReportCallout(model: viewModel.failureReport)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } leading: {
            LogActionButtons(logWindowTitle: "Installation Log")
        } trailing: {
            HiddenUntilReportAnswered(model: viewModel.failureReport) {
                if viewModel.steamInUseHolder != nil {
                    HStack {
                        Button("Start Over") {
                            viewModel.reset()
                        }
                        Button("Try Again") {
                            viewModel.retrySteamBuild()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(viewModel.isQuittingSteamHolder)
                    }
                } else {
                    Button("Start Over") {
                        viewModel.reset()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// The fallback when a game holding Steam won't quit: Second Chance quits
/// it, at the cost of anything unsaved in it. Quitting it themselves, then
/// Try Again, stays the suggestion; this sits below it, plainly worded.
private struct SteamHolderFallback: View {
    let name: String
    @EnvironmentObject var viewModel: WrappBuildViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("If \(SteamLockHolder.quoted(name)) won't quit, Second Chance can quit it for you, but anything you haven't saved in it will be lost.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Quit It for Me") {
                    viewModel.quitSteamHolderAndRetry()
                }
                .disabled(viewModel.isQuittingSteamHolder)
                if viewModel.isQuittingSteamHolder {
                    ProgressView().controlSize(.small)
                    Text("Quitting \(SteamLockHolder.quoted(name))…")
                        .foregroundStyle(.secondary)
                } else if viewModel.steamHolderDidNotQuit {
                    Text("\(SteamLockHolder.quoted(name)) didn't quit.")
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

#Preview("Error") {
    ErrorView(message: "Could not find the game installer executable")
        .environmentObject(WrappBuildViewModel())
        .frame(width: 500, height: 460)
}
