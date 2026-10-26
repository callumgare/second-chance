//
//  SettingsView.swift
//  SecondChance
//
//  Second Chance's Settings window: how much a failure report says, and
//  whether success reports are sent (docs/failure-reports.md). Both are
//  shared with every wrapp, through `ReportingPreferences`.

import SwiftUI

struct SettingsView: View {
    @State private var level = ReportingPreferences.load().level
    /// Off until the person says yes, which they're asked after their first
    /// successful build.
    @State private var successReports = ReportingPreferences.load().successReports ?? false
    @State private var showsReportContents = false
    @AppStorage(DebugCommands.settingKey) private var showDeveloperMenu = false
    private let disabledReason = FailureReporter.disabledReason(environment: ProcessInfo.processInfo.environment,
                                                                isDebugBuild: FailureReporter.isDebugBuild,
                                                                dsn: FailureReporter.dsn)

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

                DisclosureGroup(isExpanded: $showsReportContents) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Color.clear.frame(width: 0, height: 0).gridColumnAlignment(.leading)
                                .accessibilityHidden(true)
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
                } label: {
                    // The whole row toggles it, not only the chevron and the words.
                    Text("What's in a report?")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { showsReportContents.toggle() } }
                }

                disabledNote
            } header: {
                Text("Failure Reports")
            }

            Section {
                Toggle("Send success reports", isOn: $successReports)

                Text("""
                    When a game is set up or played, say whether it worked: which game, where it came from, and \
                    the Second Chance and macOS versions. Nothing about you or your files is sent. It shows which \
                    games are known to work.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                disabledNote
            } header: {
                Text("Success Reports")
            } footer: {
                Text("Reports go to the developer through Sentry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Show Developer menu", isOn: $showDeveloperMenu)
                    .disabled(DebugCommands.isAlwaysShown)

                Text(DebugCommands.isAlwaysShown
                     ? "This copy of Second Chance always shows the Developer menu."
                     : "Adds a menu with the log of what Second Chance is doing, and settings for testing it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Advanced")
            }
        }
        .formStyle(.grouped)
        // The window grows to fit, but a moment after the content does, which
        // would otherwise flash a scroller while the disclosure opens.
        .scrollIndicators(.never)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: level) { _, level in
            ReportingPreferences.update {
                $0.level = level
                // Having chosen here, nobody needs asking after a failure.
                $0.promptShown = true
            }
        }
        .onChange(of: successReports) { _, successReports in
            ReportingPreferences.update { $0.successReports = successReports }
        }
    }

    @ViewBuilder private var disabledNote: some View {
        if let disabledReason {
            Text("This copy of Second Chance doesn't send reports (\(disabledReason)).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, basic: Bool) -> some View {
        GridRow {
            Text(label)
            Image(systemName: basic ? "checkmark" : "minus").foregroundStyle(basic ? .primary : .tertiary)
                .accessibilityLabel(basic ? "In a basic report" : "Not in a basic report")
            Image(systemName: "checkmark")
                .accessibilityLabel("In a detailed report")
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
