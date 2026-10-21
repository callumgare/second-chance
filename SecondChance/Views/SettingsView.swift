//
//  SettingsView.swift
//  SecondChance
//
//  Second Chance's Settings window. For now it holds one thing: how much a
//  failure report says (docs/failure-reports.md). The choice is shared with
//  every wrapp, through `ReportingPreferences`.

import SwiftUI

struct SettingsView: View {
    @State private var level = ReportingPreferences.load().level

    var body: some View {
        Form {
            Section {
                Picker("When a build or a game fails", selection: $level) {
                    Text("Send a detailed report").tag(ReportLevel.detailed)
                    Text("Send a basic report").tag(ReportLevel.basic)
                    Text("Ask me each time").tag(ReportLevel.manual)
                }
                .pickerStyle(.radioGroup)

                Text(Self.explanation(of: level))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup("What's in a report?") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("").gridColumnAlignment(.leading)
                            Text("Basic").fontWeight(.medium)
                            Text("Detailed").fontWeight(.medium)
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        row("Second Chance and macOS versions, Mac type", basic: true)
                        row("Which game, how it was installed, its engine", basic: true)
                        row("What failed, and at which step", basic: true)
                        row("Where in Second Chance's code a crash happened", basic: true)
                        row("The log, with your name and folders taken out", basic: false)
                        row("Diagnostics from a game that failed to start", basic: false)
                    }
                    .font(.callout)
                    .padding(.top, 4)
                }

                if let reason = FailureReporter.disabledReason(environment: ProcessInfo.processInfo.environment,
                                                               isDebugBuild: FailureReporter.isDebugBuild,
                                                               dsn: FailureReporter.dsn) {
                    Text("This copy of Second Chance doesn't send reports (\(reason)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Failure Reports")
            } footer: {
                Text("Reports go to the developer through Sentry, and nothing is sent until something fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: level) { _, level in
            ReportingPreferences.update {
                $0.level = level
                // Having chosen here, nobody needs asking after a failure.
                $0.promptShown = true
            }
        }
    }

    private func row(_ label: String, basic: Bool) -> some View {
        GridRow {
            Text(label)
            Image(systemName: basic ? "checkmark" : "minus").foregroundStyle(basic ? .primary : .tertiary)
            Image(systemName: "checkmark")
        }
    }

    static func explanation(of level: ReportLevel) -> String {
        switch level {
        case .detailed:
            return "Every failure is reported with the log of what Second Chance or the game was doing, so it can be diagnosed."
        case .basic:
            return "Every failure is reported with only which game it was and what failed — enough to know it happens, rarely enough to fix it."
        case .manual:
            return "When something fails, you choose whether to send a detailed report, a basic one, or nothing."
        }
    }
}

#Preview {
    SettingsView()
}
