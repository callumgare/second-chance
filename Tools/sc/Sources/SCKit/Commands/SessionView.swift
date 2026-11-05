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
        until you press Return). The password comes from that Mac's keychain \
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
        defer {
            TestSessionAccess.tunnels.forEach { $0.terminate() }
            TestSessionAccess.tunnels.removeAll()
        }
        try await session.ui.progressStep("Opening Screen Sharing into \(host)/\(chosen)", success: "Screen Sharing is open into \(host)/\(chosen)") { _ in
            try await TestSessionAccess.openScreenSharing(chosen, on: mac)
        }
        guard mac == nil else { return }
        session.ui.line("The window goes through a tunnel this command keeps open: press Return here when you've finished with it.")
        _ = readLine()
    }
}
