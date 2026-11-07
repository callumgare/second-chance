//
//  IconLabWindow.swift
//  SecondChance
//
//  Debug ▸ Icon Lab…: designing the icons the program bundles ship, in a
//  window of its own. A tool for us, not something a player sees. The
//  first time it opens with no data of its own, it offers to move the
//  standalone lab's in.

import Logging
import ProcessKit
import SwiftUI

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab")

struct IconLabWindow: View {
    static let id = "icon-lab"

    let host: IconLabHost
    @State private var stage: Stage = .checking

    private enum Stage: Equatable {
        case checking
        case offer(URL)
        case moving(URL)
        case ready
    }

    var body: some View {
        Group {
            switch stage {
            case .ready:
                IconLabWebView(host: host)
                    .onAppear { host.startIfNeeded() }
            case .moving(let from):
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Moving Icon Lab's data in from \(from.path)…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .checking, .offer:
                Color.clear
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task { await decide() }
        .alert("Move Icon Lab's data in?", isPresented: offering, presenting: offered) { from in
            Button("Move It In") {
                // before the alert closes, so its closing doesn't start the engine in the folder first
                stage = .moving(from)
                Task { await move(from) }
            }
            Button("Start Empty", role: .cancel) { stage = .ready }
        } message: { from in
            let old = from.path, new = host.paths.data.path
            Text("The standalone Icon Lab's data is in \(old). Moving it to \(new) keeps its programs, catalogue copies and models, with nothing to download again.")
        }
    }

    private var offered: URL? {
        if case .offer(let from) = stage { return from }
        return nil
    }

    private var offering: Binding<Bool> {
        Binding(get: { offered != nil }, set: { if !$0, offered != nil { stage = .ready } })
    }

    private func decide() async {
        guard stage == .checking else { return }
        // once the engine is running the folder is its own: nothing moves in under it
        if host.isRunning {
            stage = .ready
            return
        }
        let paths = host.paths
        let from = await Blocking.run { IconLabMigration.offer(from: paths.oldData, to: paths.data) }
        stage = from.map { .offer($0) } ?? .ready
    }

    private func move(_ from: URL) async {
        let to = host.paths.data
        do {
            try await Blocking.run { try IconLabMigration.move(from, to: to) }
        } catch {
            logger.error("Couldn't move Icon Lab's data from \(from.path): \(error)")
            let alert = NSAlert()
            alert.messageText = "Icon Lab's data wasn't moved"
            alert.informativeText = "\(error.localizedDescription) It's still in \(from.path); Icon Lab starts empty."
            alert.runModal()
        }
        stage = .ready
    }
}
