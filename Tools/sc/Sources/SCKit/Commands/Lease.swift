import ArgumentParser
import Foundation

struct LeaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lease",
        abstract: "Show who has this Mac's screen, take it by hand, or give it back.",
        discussion: """
        Commands that open windows lease the screen while they run, and one \
        that finds it leased stops and says who has it. Work that takes the \
        screen without sc (an engine run by hand, a Peekaboo session, a person \
        at the Mac) takes it by hand with `take` and gives it back with \
        `release`. Usually: sc --on <host> lease. See docs/dev-cli.md#the-screen-lease.
        """,
        subcommands: [LeaseShowCommand.self, LeaseTakeCommand.self, LeaseReleaseCommand.self],
        defaultSubcommand: LeaseShowCommand.self
    )
}

struct LeaseShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show the lease (the default); --break stops its holder and clears it."
    )

    @OptionGroup var global: GlobalOptions

    @Flag(name: .customLong("break"), help: "Stop the run holding the lease (as Ctrl-C would), or clear a lease taken by hand.")
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
                let why = lease.isTakenByHand ? "it expired" : "pid \(lease.pid) has gone"
                session.ui.detail("The lease left by \(lease.summary) was stale (\(why)), and is cleared.")
            }
            return
        }
        if breakLease {
            session.ui.warning(lease.isTakenByHand ? "Clearing \(lease.who)'s lease, taken by hand."
                                                   : "Stopping \(lease.summary) (pid \(lease.pid)).")
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
        if !lease.isTakenByHand { session.ui.line("Its process: pid \(lease.pid), in \(lease.runCheckout).") }
        if let pid = lease.holder.agentPID { session.ui.line("The agent's process: pid \(pid) on \(lease.holder.host).") }
    }
}

struct LeaseTakeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "take",
        abstract: "Take the screen by hand, for work sc doesn't run, until released or expired.",
        discussion: """
        For an engine run by hand, a Peekaboo session, or someone at the Mac. \
        sc commands run by the same agent session (or the same person) go \
        ahead under it; others stop as for any lease. Taking it again renews \
        it. Give it back with `sc lease release` as soon as you're done.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Option(name: .customLong("for"), help: ArgumentHelp("How long: 30m, 2h, 90s, or minutes (at most 8h).", valueName: "time"))
    var duration: String = "30m"

    func validate() throws {
        if ScreenLease.parseDuration(duration) == nil {
            throw ValidationError("--for takes a time such as 30m, 2h or 90s, of at most 8 hours.")
        }
        if global.purpose == nil {
            throw ValidationError("Say what it's for with --purpose \"<text>\": it's what anyone it stops will see.")
        }
    }

    func run() async throws {
        let session = try Session.start(global)
        let seconds = ScreenLease.parseDuration(duration) ?? 1800
        let lease = try await ScreenLease.take(session, policy: global.leasePolicy, purpose: global.purpose, duration: seconds)
        let until = lease.expires.map(ScreenLease.clock) ?? "?"
        session.ui.detail("\(ScreenLease.shortHostName())'s screen is yours until \(until). Give it back with: sc lease release")
    }
}

struct LeaseReleaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Give back a lease taken by hand."
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let session = try Session.start(global)
        if try await ScreenLease.releaseTaken(session) {
            session.ui.detail("Released: \(ScreenLease.shortHostName())'s screen is free.")
        } else {
            session.ui.detail("\(ScreenLease.shortHostName())'s screen wasn't leased.")
        }
    }
}
