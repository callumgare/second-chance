import ArgumentParser
import Foundation

struct LeaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lease",
        abstract: "Show who has this Mac's screen, or take it back.",
        discussion: """
        Commands that open windows lease the screen while they run, and one \
        that finds it leased stops and says who has it. This shows the lease; \
        --break stops the run holding it, as Ctrl-C would. Usually: \
        sc --on <host> lease. See docs/dev-cli.md#the-screen-lease.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Flag(name: .customLong("break"), help: "Stop the run holding the lease (as Ctrl-C would) and clear it.")
    var breakLease = false

    @Flag(help: "Print the lease as JSON.")
    var json = false

    func run() async throws {
        let session = try Session.start(global)
        let file = ScreenLease.file()
        guard let lease = ScreenLease.read(file) else {
            if json { session.ui.line("null") } else { session.ui.detail("\(ScreenLease.shortHostName())'s screen isn't leased.") }
            return
        }
        guard lease.isAlive else {
            try? FileManager.default.removeItem(at: file)
            if json { session.ui.line("null") } else {
                session.ui.detail("The lease left by \(lease.summary) was stale (pid \(lease.pid) has gone), and is cleared.")
            }
            return
        }
        if breakLease {
            session.ui.warning("Stopping \(lease.summary) (pid \(lease.pid)).")
            try await ScreenLease.stopHolder(lease)
            try? FileManager.default.removeItem(at: file)
            session.ui.detail("The screen is free.")
            return
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            session.ui.line(String(decoding: try encoder.encode(lease), as: UTF8.self))
            return
        }
        session.ui.line(lease.heldMessage(onHost: ScreenLease.shortHostName()))
        session.ui.line("Its process: pid \(lease.pid), in \(lease.runCheckout).")
        if let pid = lease.holder.agentPID { session.ui.line("The agent's process: pid \(pid) on \(lease.holder.host).") }
    }
}
