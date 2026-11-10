import Foundation

/// Pictures taken on screen in one of this Mac's test sessions
/// (docs/dev-cli.md#test-sessions) rather than on the console: nothing comes
/// up on the screen of the person at the Mac, and the pictures take the scale
/// of the session's own display (Screen Sharing's, 2×), not of the Mac's
/// monitors: Retina ones on a Mac with only a 1× monitor attached.
extension Screenshots {
    /// Whether one of this Mac's test sessions is free to take pictures in.
    static func freeTestSession() async -> Bool {
        await SessionPool.statuses().contains(where: \.isFree)
    }

    /// As `take(targets:states:onScreen:into:)` on screen, in `user`'s test
    /// session, or the first free one: claimed for the while, the app copied
    /// into it, each target's states drawn in its GUI login, the pictures
    /// copied back into `folder`, and the session given back.
    func takeInTestSession(_ user: String?, targets: [Target], states: [String], into folder: URL) async throws -> [URL] {
        let purpose = session.purpose ?? "Pictures of the app's windows (sc screenshot)"
        let (chosen, _) = try await SessionClaimCommand.claim(user, seconds: 15 * 60, session: session,
                                                              policy: session.leasePolicy, purpose: purpose)
        let destination = "\(chosen)@localhost"
        session.ui.detail("Picturing in \(SessionPool.screenName(of: chosen))")
        // Its own folder there, which nothing else uses, removed afterwards.
        var remote: String?
        let finish = { [session] in
            if let remote { _ = try? await TestSessionAccess.ssh(destination, "rm -rf \(Remote.quote(remote))") }
            _ = try? await ScreenLease.releaseTaken(session, user: chosen)
        }
        do {
            let home = try await ssh(destination, "echo $HOME").trimmingCharacters(in: .whitespacesAndNewlines)
            guard home.hasPrefix("/") else { throw SCError("Couldn't find \(destination)'s home folder.") }
            let folderThere = "\(home)/tmp/sc-screenshots-\(UUID().uuidString)"
            remote = folderThere
            let pictures = try await take(in: destination, remote: folderThere,
                                          targets: targets, states: states, into: folder)
            await finish()
            return pictures
        } catch {
            await finish()
            throw error
        }
    }

    private func take(in destination: String, remote: String, targets: [Target], states: [String], into folder: URL) async throws -> [URL] {

        // tar, not cp or rsync, so the app's code signature arrives whole.
        try await bash(
            "tar -c -C \(Remote.quote(app.deletingLastPathComponent().path)) \(Remote.quote(app.lastPathComponent))"
                + " | ssh -o BatchMode=yes \(destination) \(Remote.quote("mkdir -p \(Remote.quote(remote)) && tar -x -C \(Remote.quote(remote))"))",
            failing: "Couldn't copy the app into \(destination)"
        )
        let copied = URL(fileURLWithPath: remote).appendingPathComponent(app.lastPathComponent)
        let remotePictures = "\(remote)/pictures"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var drawn: [URL] = []
        for target in targets {
            var env = ["SECOND_CHANCE_UI_STATES=\(remotePictures)", "SECOND_CHANCE_UI_STATES_ON_SCREEN=1", "SECOND_CHANCE_LOG_STDERR=1"]
            if !states.isEmpty { env.append("SECOND_CHANCE_UI_STATES_ONLY=\(states.joined(separator: ","))") }
            let program = ["/usr/bin/env"] + env + [Self.executable(of: target, in: copied).path]
            let script = TestSessionAccess.inGUISession(program, timeout: 300, withErrors: true)
            _ = try await session.ui.logStep("Picture \(target.rawValue) states in a test session", log: "screenshot-\(target.rawValue)",
                                         success: "Pictured \(target.rawValue) states") { sink in
                let status = try await Proc.stream("/usr/bin/ssh", ["-o", "BatchMode=yes", destination, "bash -s"], input: script) {
                    await sink.line($0)
                }
                guard status == 0 else { throw SCError("Picturing \(target.rawValue)'s states in \(destination) failed (exit \(status)).") }
                return status
            }
        }

        // Back here, then what came back is what this run drew.
        let received = folder.appendingPathComponent(".from-test-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: received, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: received) }
        try await bash(
            "ssh -o BatchMode=yes \(destination) \(Remote.quote("tar -c -C \(Remote.quote(remotePictures)) ."))"
                + " | tar -x -C \(Remote.quote(received.path))",
            failing: "Couldn't copy the pictures back from \(destination)"
        )
        for picture in Self.pictures(in: received) {
            let target = folder.appendingPathComponent(picture.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: picture, to: target)
            drawn.append(target)
        }
        guard !drawn.isEmpty else { throw SCError("Nothing was pictured in \(destination).") }
        return drawn.sorted { $0.path < $1.path }
    }

    private func ssh(_ destination: String, _ command: String) async throws -> String {
        let result = try await TestSessionAccess.ssh(destination, command)
        guard result.succeeded else { throw SCError("ssh \(destination) failed: \(result.error)") }
        return result.output
    }

    private func bash(_ command: String, failing message: String) async throws {
        let result = try await Proc.collect("/bin/bash", ["-o", "pipefail", "-c", command])
        guard result.succeeded else { throw SCError("\(message).", hints: [result.error]) }
    }
}
