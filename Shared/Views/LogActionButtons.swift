//
//  LogActionButtons.swift
//  Shared
//
//  Reusable Show Logs / Save Logs button pair for error screens.

import SwiftUI

public struct LogActionButtons: View {
    @ObservedObject var logWindow = LogWindow.shared
    @State private var isSavingLogs = false
    @State private var showSaveFailedAlert = false

    private let logWindowTitle: String
    private let saveFileNamePrefix: String

    public init(logWindowTitle: String = "Log", saveFileNamePrefix: String = "second-chance") {
        self.logWindowTitle = logWindowTitle
        self.saveFileNamePrefix = saveFileNamePrefix
    }

    public var body: some View {
        HStack(spacing: 15) {
            Button {
                logWindow.showLogWindow(title: logWindowTitle)
            } label: {
                Label("Show Logs", systemImage: "doc.text")
            }
            .disabled(logWindow.isVisible)

            Button {
                isSavingLogs = true
                Task {
                    guard let url = LogExporter.selectSaveURL(fileNamePrefix: saveFileNamePrefix) else {
                        isSavingLogs = false
                        return
                    }
                    let ok = await LogExporter.export(to: url)
                    isSavingLogs = false
                    if !ok { showSaveFailedAlert = true }
                }
            } label: {
                if isSavingLogs {
                    Label("Saving…", systemImage: "hourglass")
                } else {
                    Label("Save Logs", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(isSavingLogs)
        }
        .alert("Save Failed", isPresented: $showSaveFailedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The log file could not be saved. Please try again.")
        }
    }
}
