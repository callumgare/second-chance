//
//  WelcomeView.swift
//  SecondChance
//
//  Welcome screen: choosing where to install the game from

import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var viewModel: WrappBuildViewModel
    @ObservedObject var debugSettings = DebugSettings.shared
    @State private var selection: WrappSource? = .disk

    private var sources: [WrappSource] {
        debugSettings.showUnsupportedInstallOptions ? [.disk, .steam, .herDownload] : [.disk, .steam]
    }

    var body: some View {
        InstallerPage(title: "Welcome back, Detective") {
            Text("Second Chance makes a Nancy Drew game playable on this Mac. Choose where to install it from.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            WrappSourcePicker(sources: sources, selection: $selection, onChoose: start)
        } leading: {
            EmptyView()
        } trailing: {
            Button("Continue") {
                if let selection { start(selection) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selection == nil)
        }
        .onChange(of: sources) { _, sources in
            if let selection, !sources.contains(selection) { self.selection = .disk }
        }
    }

    private func start(_ source: WrappSource) {
        Task { await viewModel.build(from: source) }
    }
}

/// The sources as a single-selection list: click or arrow keys to select,
/// double-click to choose. A plain stack rather than a `List`, which is a
/// scroll view and nudges its rows up to reveal the one selected.
struct WrappSourcePicker: View {
    let sources: [WrappSource]
    @Binding var selection: WrappSource?
    let onChoose: (WrappSource) -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sources) { source in
                WrappSourceRow(source: source, isSelected: source == selection, isEmphasized: isEmphasized)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onChoose(source) }
                    .simultaneousGesture(TapGesture().onEnded {
                        selection = source
                        isFocused = true
                    })
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(source == selection ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { onChoose(source) }
                    .accessibilityIdentifier(source.accessibilityIdentifier)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor)))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
    }

    /// Selected rows are drawn in the accent colour while the picker has
    /// focus in the key window, and grey otherwise, as a list's are.
    private var isEmphasized: Bool {
        isFocused && activeState == .key
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let index = selection.flatMap { sources.firstIndex(of: $0) } ?? -offset
        let next = min(max(index + offset, 0), sources.count - 1)
        selection = sources[next]
        return .handled
    }
}

struct WrappSourceRow: View {
    let source: WrappSource
    let isSelected: Bool
    let isEmphasized: Bool

    var body: some View {
        // The icon sits as far from the text as from the picker's edge.
        HStack(spacing: 12) {
            source.icon
                .resizable()
                .scaledToFit()
                .frame(width: 21, height: 21)
                .foregroundStyle(secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .foregroundStyle(primaryText)
                Text(source.description)
                    .font(.callout)
                    .foregroundStyle(secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(background)
    }

    private var onAccent: Bool { isSelected && isEmphasized }

    private var primaryText: Color {
        onAccent ? Color(nsColor: .alternateSelectedControlTextColor) : .primary
    }

    private var secondaryText: Color {
        onAccent ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.8) : .secondary
    }

    private var background: Color {
        guard isSelected else { return .clear }
        return Color(nsColor: isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
    }
}

private extension WrappSource {
    /// An SF Symbol, or for Steam its logo (a template image in the asset
    /// catalog, from Simple Icons), drawn at the same size.
    var icon: Image {
        switch self {
        case .disk: return Image(systemName: "opticaldisc")
        case .steam: return Image("SteamLogo")
        case .herDownload: return Image(systemName: "arrow.down.circle")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .disk: return "installSourceDisk"
        case .steam: return "installSourceSteam"
        case .herDownload: return "installSourceHerDownload"
        }
    }
}

#Preview {
    WelcomeView()
        .environmentObject(WrappBuildViewModel())
        .frame(width: 500, height: 460)
}
