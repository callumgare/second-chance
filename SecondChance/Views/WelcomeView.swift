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

            List(sources, selection: $selection) { source in
                WrappSourceRow(source: source)
                    // No vertical insets, so a row is exactly `height` tall
                    // and the list can be sized to fit them.
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                    .tag(source)
                    .accessibilityIdentifier(source.accessibilityIdentifier)
            }
            .listStyle(.bordered)
            .scrollDisabled(true)
            // Only as tall as its rows: a near-empty box looks unfinished.
            .frame(height: CGFloat(sources.count) * WrappSourceRow.height + 1)
            .contextMenu(forSelectionType: WrappSource.self) { _ in
            } primaryAction: { sources in
                // A double-click, or Return in the list.
                if let source = sources.first { start(source) }
            }
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

struct WrappSourceRow: View {
    let source: WrappSource
    /// Each row's height in the list.
    static let height: CGFloat = 52

    var body: some View {
        // The icon sits as far from the text as from the list's edge.
        HStack(spacing: 12) {
            source.icon
                .resizable()
                .scaledToFit()
                .frame(width: 21, height: 21)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                Text(source.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: Self.height)
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
