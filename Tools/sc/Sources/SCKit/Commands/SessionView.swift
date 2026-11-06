import ArgumentParser
import Foundation

/// A Screen Sharing window here into a test session, as `session setup`
/// opens one: to watch a run, or to do something by hand there.
struct SessionViewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "Open a Screen Sharing window here into a test session, logged in.",
        discussion: """
        With --on, into that Mac's test session; without, this Mac's (through an \
        SSH tunnel, as Screen Sharing won't connect a Mac to itself, kept open \
        until the window closes or you press Return). The password comes from that Mac's keychain \
        and goes straight to Screen Sharing, never saved. If Screen Sharing asks, \
        choose "Log in as yourself".
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The test user. Default: the Mac's only one.")
    var user: String?

    func run() async throws {
        let session = try Session.start(global)
        let mac = Invocation.remote.map { Remote.parse($0, localRoot: session.repo.root).host }
        let host = mac ?? ScreenLease.shortHostName()
        let chosen: String
        if let user {
            chosen = user
        } else {
            let pool = try await session.ui.progressStep("Reading the list of test accounts on \(host)") { _ in
                SessionPool.users(fromPool: try await TestSessionAccess.asConsoleUser(mac, "cat \(SessionPool.file.path) 2>/dev/null").output)
            }
            guard pool.count == 1, let only = pool.first else {
                throw SCError(pool.isEmpty ? "\(host) has no test sessions." : "Which test session? \(host) has \(pool.joined(separator: ", ")).",
                              hints: pool.isEmpty ? ["Add some there: sc session add"]
                                                  : ["Name one: sc session view <user>" + (mac.map { " --on \($0)" } ?? "")])
            }
            chosen = only
        }
        // Watching disturbs nothing, so it goes ahead; but what's done by hand
        // there could disturb whoever has it, so say who.
        let holder = ScreenLease.currentHolder(repoRoot: session.repo.root, branch: await ScreenLease.branch(of: session.repo.root))
        if let lease = try? await SessionSetupCommand.othersLeases([chosen], on: mac, holder: holder).first?.lease {
            let purpose: String = lease.purpose.map { " for \"\($0)\"" } ?? ""
            let until: String = lease.expires.map { " until \(ScreenLease.clock($0))" } ?? ""
            let message: String = "\(chosen)@\(host) is leased to \(lease.who)\(purpose)\(until): watch, but leave what runs there alone."
            session.ui.warning("\(message)")
        }
        defer {
            TestSessionAccess.tunnels.forEach { $0.terminate() }
            TestSessionAccess.tunnels.removeAll()
        }
        try await session.ui.progressStep("Opening Screen Sharing into \(chosen)@\(host)", success: "Screen Sharing is open into \(chosen)@\(host)") { _ in
            try await TestSessionAccess.openScreenSharing(chosen, on: mac, tunnelEndsWithWindow: true)
        }
        guard mac == nil else { return }
        session.ui.line("The window goes through a tunnel this command keeps open until you close the window (or press Return here).")
        await TestSessionAccess.untilTunnelsEndOrReturn()
    }
}
