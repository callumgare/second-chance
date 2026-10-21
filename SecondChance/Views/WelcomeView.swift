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
    /// Each row's height in the list, its insets included.
    static let height: CGFloat = 56

    var body: some View {
        HStack(spacing: 12) {
            source.icon
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                Text(source.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: Self.height - 12)
    }
}

private extension WrappSource {
    /// An SF Symbol, or for Steam its logo (a template image in the asset
    /// catalog, from Simple Icons) sized to match one.
    @ViewBuilder var icon: some View {
        switch self {
        case .disk: Image(systemName: "opticaldisc").font(.title2)
        case .steam: Image("SteamLogo").resizable().scaledToFit().frame(width: 21, height: 21)
        case .herDownload: Image(systemName: "arrow.down.circle").font(.title2)
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
