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
        InstallerPage(title: "Welcome, Detective") {
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
/// double-click or Return to choose.
struct WrappSourcePicker: View {
    let sources: [WrappSource]
    @Binding var selection: WrappSource?
    let onChoose: (WrappSource) -> Void
    /// The list's height: grown or shrunk by however far its rows overflow
    /// or underfill what it shows, which settles in one step whatever the
    /// border and insets come to on this version of macOS.
    @State private var height: CGFloat?
    /// How far down the list moves to start on a whole pixel. Off the pixel
    /// grid, the clip view snaps its rows to it one way at rest and the other
    /// once a selection is scrolled to, nudging them by a fraction of a point.
    @State private var pixelAlignment: CGFloat = 0
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        List(sources, selection: $selection) { source in
            WrappSourceRow(source: source)
                // A separator would take its height from the row above.
                .listRowSeparator(.hidden)
                .tag(source)
                .accessibilityIdentifier(source.accessibilityIdentifier)
        }
        .listStyle(.bordered)
        .scrollDisabled(true)
        // Exactly as tall as its rows. A list scrolls its selection into
        // view, so one even a point shorter than its content nudges every
        // row up when the last is selected; one taller leaves a gap under it.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                - geometry.containerSize.height
        } action: { _, overflow in
            guard abs(overflow) > 0.01 else { return }
            height = max((height ?? 0) + overflow, 1)
        }
        .frame(height: height)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { minY in
            let aligned = (minY * displayScale).rounded(.up) / displayScale
            if aligned - minY > 0.001 { pixelAlignment += aligned - minY }
        }
        .padding(.top, pixelAlignment)
        .contextMenu(forSelectionType: WrappSource.self) { _ in
        } primaryAction: { sources in
            if let source = sources.first { onChoose(source) }
        }
        .accessibilityLabel("Install from")
    }
}

struct WrappSourceRow: View {
    let source: WrappSource

    var body: some View {
        // The icon as far from the list's edge as from the text: the list's
        // own inset is 6pt, and the glyphs start half a point in.
        HStack(spacing: 11.5) {
            source.icon
                .resizable()
                .scaledToFit()
                .frame(width: 21, height: 21)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                Text(source.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // Centres the glyphs rather than their line boxes, which leave
            // more room above the capitals than below the descenders.
            .padding(.bottom, 3)
        }
        .padding(.leading, 6)
        .frame(height: 44)
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
