//
//  LogWindowView.swift
//  Shared
//
//  SwiftUI rendering for the floating log window: a Console-style table with
//  Time/Level/Category/Message columns, level-tinted rows, and an options bar
//  above the column headers (level filter, compact two-column mode, line
//  counts). The display state lives in `LogDisplayModel`, owned by
//  `LogWindow` — the hosted view observes the model directly so nothing in
//  the SwiftUI subtree needs a reference back to the window controller.
//

import SwiftUI
import AppKit
import Combine

// MARK: - Display Model

/// View-bound state for the log window. Kept separate from `LogWindow`
/// itself so the hosted SwiftUI view can observe it without forming a
/// reference cycle through the window controller.
final class LogDisplayModel: ObservableObject {
    /// Rows currently held by the view, oldest first. Bounded to roughly the
    /// last `LogWindow.maxViewLines` entries; the store keeps the full
    /// history for export.
    @Published var rows: [LogRow] = []
    /// Lines dropped from the head of the view (burst overflow + trimming).
    /// Surfaced in the options bar; the full history remains via Save Logs.
    @Published var hiddenLineCount = 0
    /// Which levels are shown.
    @Published var levelFilter: LogLevelFilter = .all
    /// When set, only the Level and Message columns are shown.
    @Published var compactMode = false
}

// MARK: - Row Model

/// One row in the log table, built from a `LogStore` entry.
nonisolated struct LogRow: Identifiable, Hashable, Sendable {
    let id: UInt64
    let time: String
    let level: String
    let category: String
    let message: String

    init(entry: Entry) {
        id = entry.seq
        time = LogFormatter.time(entry: entry)
        level = LogFormatter.formatLevel(entry.level)
        category = LogFormatter.extractCategory(from: entry.label)
        if let error = entry.error, !error.isEmpty {
            message = "\(entry.message) — Error: \(error)"
        } else {
            message = entry.message
        }
    }

    /// Single-line rendering (time, level, category, message) used by
    /// Copy Row and test assertions.
    var compactLine: String { "\(time)  \(level)  \(category)  \(message)" }
}

// MARK: - Level Filter

/// Which log levels the window shows.
enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all
    case warnings
    case errors

    var id: Self { self }

    var label: String {
        switch self {
        case .all: "All"
        case .warnings: "Warnings"
        case .errors: "Errors"
        }
    }

    /// Whether a row at `level` (compact-normalized by `formatLevel`) passes.
    func includes(level: String) -> Bool {
        switch self {
        case .all:
            return true
        case .warnings:
            return Self.rank(level) >= Self.rank("warning")
        case .errors:
            return Self.rank(level) >= Self.rank("error")
        }
    }

    /// Severity ranking matching `LogFormatter.formatLevel`'s coalescing
    /// (trace/debug → debug, info/notice → notice).
    private static func rank(_ level: String) -> Int {
        switch level.lowercased() {
        case "trace", "debug": return 0
        case "info", "notice": return 1
        case "warning": return 2
        case "error": return 3
        case "critical": return 4
        default: return 1
        }
    }
}

// MARK: - Level Colors

/// Row tinting: more severe levels get stronger colour so they stand out
/// while scrolling, like Console.app.
enum LogLevelStyle {
    nonisolated static func tint(for level: String) -> Color {
        switch level.lowercased() {
        case "critical": return .purple
        case "error": return .red
        case "warning": return .orange
        case "trace", "debug": return .secondary
        default: return .primary
        }
    }
}

/// Table cell text with its level tint. A concrete type so every column's
/// content has one identity, keeping the TableColumnBuilder happy.
private struct LogCell: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .foregroundStyle(tint)
    }
}

// MARK: - Main View

/// The log window's content: an options bar above a Console-style table.
struct LogWindowView: View {
    @ObservedObject var model: LogDisplayModel
    @State private var selection: LogRow.ID?

    private var filteredRows: [LogRow] {
        model.rows.filter { model.levelFilter.includes(level: $0.level) }
    }

    var body: some View {
        VStack(spacing: 0) {
            LogFilterBar(
                model: model,
                shownCount: filteredRows.count,
                totalCount: model.rows.count
            )
            Divider()
            logTable
        }
    }

    private var logTable: some View {
        tableContent
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .overlay {
                if filteredRows.isEmpty {
                    emptyState
                }
            }
            .contextMenu(forSelectionType: LogRow.self) { rows in
                let ordered = rows.sorted { $0.id < $1.id }

                Button("Copy Row") {
                    copy(ordered.map(\.compactLine))
                }
                .disabled(ordered.isEmpty)

                Button("Copy Message") {
                    copy(ordered.map(\.message))
                }
                .disabled(ordered.isEmpty)

                Divider()

                Button("Copy All Visible Lines") {
                    copy(filteredRows.map(\.compactLine))
                }
                .disabled(filteredRows.isEmpty)
            }
    }

    /// Compact mode swaps the whole table — SwiftUI's column builder cannot
    /// build columns conditionally — which resets the scroll position;
    /// `LogWindow` re-follows the tail after the swap.
    @ViewBuilder
    private var tableContent: some View {
        if model.compactMode {
            compactTable
        } else {
            fullTable
        }
    }

    /// Two columns only: Level and Message.
    private var compactTable: some View {
        Table(filteredRows, selection: $selection) {
            TableColumn("Level") { row in
                LogCell(text: row.level, tint: LogLevelStyle.tint(for: row.level))
            }
            .width(76)

            TableColumn("Message") { row in
                LogCell(text: row.message, tint: LogLevelStyle.tint(for: row.level))
            }
            .width(min: 200)
        }
    }

    /// Full Console-style layout: Time, Level, Category, Message.
    private var fullTable: some View {
        Table(filteredRows, selection: $selection) {
            TableColumn("Time") { row in
                LogCell(text: row.time, tint: .secondary)
            }
            .width(96)

            TableColumn("Level") { row in
                LogCell(text: row.level, tint: LogLevelStyle.tint(for: row.level))
            }
            .width(76)

            TableColumn("Category") { row in
                LogCell(text: row.category, tint: .secondary)
            }
            .width(150)

            TableColumn("Message") { row in
                LogCell(text: row.message, tint: LogLevelStyle.tint(for: row.level))
            }
            .width(min: 240)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.rows.isEmpty {
            ContentUnavailableView(
                "No Logs",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Log lines will appear here as the app runs.")
            )
        } else {
            ContentUnavailableView(
                "No Matching Lines",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Nothing at the selected level — switch back to All.")
            )
        }
    }

    private func copy(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Options Bar

/// The small options bar above the log lines and column headers: level
/// filter, compact mode toggle, and line counts.
private struct LogFilterBar: View {
    @ObservedObject var model: LogDisplayModel
    let shownCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 14) {
            Picker("Show", selection: $model.levelFilter) {
                ForEach(LogLevelFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .help("Show all lines, only warnings and above, or only errors and above.")

            Toggle("Compact", isOn: $model.compactMode)
                .toggleStyle(.checkbox)
                .help("Show only the Level and Message columns.")

            Spacer(minLength: 8)

            if model.levelFilter != .all {
                Text("\(shownCount) of \(totalCount) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.hiddenLineCount > 0 {
                Text("\(model.hiddenLineCount) earlier lines hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Only the most recent \(LogWindow.maxViewLines) lines are kept in view. Use Save Logs for the full history.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
