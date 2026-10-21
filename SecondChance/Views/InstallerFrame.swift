//
//  InstallerFrame.swift
//  SecondChance
//
//  The main window's chrome, after Installer.app: a sidebar listing the
//  steps of a build, and a page with a heading, its content, and a bar of
//  buttons along the bottom.

import SwiftUI

/// The steps the sidebar lists: the build's states, grouped into the few a
/// player cares about.
enum InstallerStep: Int, CaseIterable {
    case source
    case preparation
    case installation
    case configuration
    case summary

    var title: String {
        switch self {
        case .source: return "Source"
        case .preparation: return "Preparation"
        case .installation: return "Installation"
        case .configuration: return "Configuration"
        case .summary: return "Summary"
        }
    }

    /// The step `state` belongs to. Nil for an error, which belongs to
    /// whichever step it interrupted.
    init?(_ state: WrappBuildState) {
        switch state {
        case .idle, .selectingWrappSource, .selectingSource: self = .source
        case .detectingGame, .settingUpWrapp, .copyingInstaller: self = .preparation
        case .installingGame: self = .installation
        case .configuringWrapp, .savingApp: self = .configuration
        case .completed: self = .summary
        case .error: return nil
        }
    }
}

struct InstallerSidebar: View {
    let current: InstallerStep
    /// The step a failure interrupted, marked as failed.
    let failed: InstallerStep?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .padding(.bottom, 14)

            ForEach(InstallerStep.allCases, id: \.self) { step in
                HStack(spacing: 8) {
                    Circle()
                        .fill(bulletColor(step))
                        .frame(width: 7, height: 7)
                    Text(step.title)
                        .fontWeight(step == current ? .semibold : .regular)
                        .foregroundStyle(step == current ? .primary : .secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(width: 180, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(VisualEffectBackground(material: .sidebar))
    }

    private func bulletColor(_ step: InstallerStep) -> Color {
        if step == failed { return .red }
        return step == current ? .accentColor : Color(nsColor: .tertiaryLabelColor)
    }
}

/// One page of the main window: its heading and content, and the bar of
/// buttons beneath them.
struct InstallerPage<Content: View, Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    /// Secondary actions, at the bar's leading edge.
    @ViewBuilder var leading: () -> Leading
    /// The page's way on, at the bar's trailing edge; its default button
    /// takes Return.
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack {
                leading()
                Spacer()
                trailing()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// An AppKit material behind SwiftUI content, for the sidebar.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
