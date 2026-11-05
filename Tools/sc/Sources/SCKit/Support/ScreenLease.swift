import Darwin
import Foundation

/// Who has a Mac's screen: one lease per Mac, taken by every command that
/// opens windows (`GUISession.ensure`), so two runs never fight over it.
///
/// Several agents, each in its own checkout, share a test Mac. A game launched
/// during another's integration run takes the focus and fails that run's
/// tests, so a command that finds the screen leased stops at once and says who
/// has it, for what, since when, and how to reach them — rather than waiting,
/// which would hide an hours-long run behind a silent hang.
///
/// The holder is recorded by who asked, not only by the process: a Claude Code
/// session passes its messaging socket, session id and pid to everything it
/// runs (`CLAUDE_CODE_*`), so a blocked agent can message the holder. `--on`
/// carries that identity to the other Mac in `SC_LEASE_HOLDER`, since ssh
/// passes no environment. The session's messaging token is never recorded.
///
/// The lease lives as long as the process that took it: one whose process has
/// gone (it crashed, or the Mac restarted) is stale and is taken over.
struct ScreenLease: Codable, Equatable, Sendable {
    /// Who asked for the screen, wherever they typed the command.
    struct Holder: Codable, Equatable, Sendable {
        /// A Claude Code session's messaging socket: what peers message it by
        /// (`uds:<socket>`), and what `ListAgents` maps to its name.
        var agentSocket: String?
        var sessionID: String?
        /// The agent's process, on the Mac the command was typed on.
        var agentPID: Int32?
        /// The Mac, user and checkout the command was typed in.
        var host: String
        var user: String
        var checkout: String
        var branch: String?
    }

    var holder: Holder
    var purpose: String?
    var command: String
    /// The checkout the run is in, on the leased Mac (for `sc attach`).
    var runCheckout: String
    /// The process holding the lease, and when it started, so a reused pid
    /// isn't mistaken for it.
    var pid: Int32
    var pidStarted: Double
    var started: Date

    /// What to do about a lease someone else holds.
    enum Policy: Sendable {
        /// Stop, saying who holds it.
        case respect
        /// Go ahead regardless, leaving their lease in place.
        case ignore
        /// Stop their run (as Ctrl-C does), then take the lease.
        case breakIt
    }

    static let holderVariable = "SC_LEASE_HOLDER"
    static let fileVariable = "SC_SCREEN_LEASE_FILE"
    /// The exit status when the screen is leased: EX_TEMPFAIL.
    static let heldExitCode: Int32 = 75

    /// Per Mac, outside any checkout, so every checkout there sees it.
    static func file(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[fileVariable], !path.isEmpty { return URL(fileURLWithPath: path) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("au.gare.callum.second-chance.sc/screen-lease.json")
    }

    // MARK: Who's asking

    /// The holder handed over by `--on` from the Mac it was typed on, or
    /// else this process's own: its agent session, if any, Mac and checkout.
    static func currentHolder(repoRoot: URL, branch: String?,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> Holder {
        if let encoded = environment[holderVariable], let holder = decodeHolder(encoded) { return holder }
        return Holder(
            agentSocket: environment["CLAUDE_CODE_MESSAGING_SOCKET"].flatMap { $0.isEmpty ? nil : $0 },
            sessionID: environment["CLAUDE_CODE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 },
            agentPID: environment["CLAUDE_PID"].flatMap { Int32($0) },
            host: shortHostName(),
            user: NSUserName(),
            checkout: repoRoot.path,
            branch: branch
        )
    }

    /// Base64 of the holder's JSON: one shell-safe word to put on the remote
    /// command line, whatever the login shell there.
    static func encodeHolder(_ holder: Holder) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(holder)) ?? Data()
        return data.base64EncodedString()
    }

    static func decodeHolder(_ encoded: String) -> Holder? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(Holder.self, from: data)
    }

    /// The Mac's name as it's used to reach it: `meeka`, not `meeka.local`
    /// or `meeka.<network>.internal`.
    static func shortHostName(_ name: String = ProcessInfo.processInfo.hostName) -> String {
        String(name.split(separator: ".").first ?? Substring(name))
    }

    /// The command as it would be typed, words with spaces quoted.
    static func commandLine(_ arguments: [String]) -> String {
        (["sc"] + arguments.map { $0.contains(where: { " '\"".contains($0) }) ? Remote.quote($0) : $0 }).joined(separator: " ")
    }

    static func branch(of repoRoot: URL) async -> String? {
        guard let result = try? await Proc.collect("/usr/bin/git", ["-C", repoRoot.path, "rev-parse", "--abbrev-ref", "HEAD"]),
              result.status == 0 else { return nil }
        let branch = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    // MARK: Taking and giving back

    /// The lease this process holds, released when sc exits.
    nonisolated(unsafe) private static var held: URL?

    /// Take the screen for this process, or throw saying who has it.
    static func acquire(_ session: Session, policy: Policy, purpose: String?) async throws {
        let file = file()
        let holder = currentHolder(repoRoot: session.repo.root, branch: await branch(of: session.repo.root))
        let lease = ScreenLease(
            holder: holder, purpose: purpose, command: commandLine(Invocation.arguments),
            runCheckout: session.repo.root.path, pid: getpid(), pidStarted: ProcessFacts.startTime(of: getpid()) ?? 0,
            started: Date()
        )
        for _ in 0..<3 {
            if try create(lease, at: file) {
                held = file
                atexit { ScreenLease.release() }
                return
            }
            guard let existing = read(file) else {
                // Unreadable or half-written: older than a second means it's junk.
                removeIfOld(file)
                continue
            }
            if !existing.isAlive {
                session.ui.detail("Took over a stale screen lease (\(existing.command), pid \(existing.pid) has gone).")
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if existing.pid == getpid() || ProcessFacts.isAncestor(existing.pid, of: getpid()) {
                return  // Ours already: a re-run or a command sc started.
            }
            switch policy {
            case .respect:
                throw SCError(existing.heldMessage(onHost: shortHostName()), hints: existing.hints(onHost: shortHostName(), askingSession: holder.sessionID),
                              exitCode: heldExitCode)
            case .ignore:
                session.ui.warning("Going ahead although \(existing.summary) has the screen (--ignore-screen-lease). Its windows and ours may get in each other's way.")
                return
            case .breakIt:
                session.ui.warning("Breaking the screen lease: stopping \(existing.summary) (pid \(existing.pid)).")
                try await stopHolder(existing)
                try? FileManager.default.removeItem(at: file)
            }
        }
        throw SCError("Couldn't take the screen lease at \(file.path): it kept changing under sc.")
    }

    /// Give the screen back, if this process has it and it's still ours.
    static func release() {
        guard let file = held else { return }
        held = nil
        if let lease = read(file), lease.pid == getpid() {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Write the lease only if there's none: link(2) of a finished temporary
    /// file is atomic and fails if the name exists, so two runs starting at
    /// once can't both win, and a reader never sees half a file.
    static func create(_ lease: ScreenLease, at file: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = file.deletingLastPathComponent().appendingPathComponent(".lease-\(getpid())-\(UUID().uuidString)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(lease).write(to: temp)
        defer { unlink(temp.path) }
        if link(temp.path, file.path) == 0 { return true }
        guard errno == EEXIST else {
            throw SCError("Couldn't write the screen lease at \(file.path): \(String(cString: strerror(errno))).")
        }
        return false
    }

    static func read(_ file: URL) -> ScreenLease? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScreenLease.self, from: data)
    }

    private static func removeIfOld(_ file: URL) {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, Date().timeIntervalSince(modified) > 1 {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Stop the holder as Ctrl-C would, so it cleans up after itself, and
    /// wait for it to go.
    static func stopHolder(_ lease: ScreenLease) async throws {
        kill(lease.pid, SIGINT)
        let deadline = Date().addingTimeInterval(120)
        while lease.isAlive, Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
        }
        if lease.isAlive {
            throw SCError("\(lease.summary) (pid \(lease.pid)) didn't stop within 2 minutes of being asked, so the screen is still theirs.",
                          hints: ["See what it's doing: sc lease", "Stop it yourself (by its pid), then run this again."])
        }
    }

    // MARK: Describing it

    /// The process that took it is still the one running under that pid.
    var isAlive: Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let start = ProcessFacts.startTime(of: pid) else { return false }
        return abs(start - pidStarted) < 1
    }

    var who: String {
        if let socket = holder.agentSocket { return "the agent session at \(socket)" }
        return "\(holder.user) on \(holder.host)"
    }

    var summary: String {
        "\(who)'s `\(command)`"
    }

    func heldMessage(onHost host: String, now: Date = Date()) -> String {
        var lines = ["\(host)'s screen is in use: \(who) is running `\(command)`, for \(Self.duration(now.timeIntervalSince(started))) so far."]
        if let purpose { lines.append("Purpose: \(purpose)") }
        var from = "From \(holder.host), \(holder.checkout)"
        if let branch = holder.branch { from += " (branch \(branch))" }
        lines.append(from + ".")
        if let session = holder.sessionID { lines.append("Session id: \(session)") }
        return lines.joined(separator: "\n")
    }

    func hints(onHost host: String, askingSession: String?) -> [String] {
        var hints: [String] = []
        if let session = holder.sessionID, session == askingSession {
            hints.append("That's this same agent session: let the other run finish, or stop it, first.")
        } else if let socket = holder.agentSocket {
            hints.append("Ask that session when it'll be done: SendMessage to uds:\(socket) (ListAgents shows its name).")
        }
        hints.append("Watch it: sc --on \(host):\(runCheckout) attach")
        hints.append("Go ahead anyway, leaving the lease (windows may clash): add --ignore-screen-lease")
        hints.append("Stop that run and take the screen: add --break-screen-lease")
        return hints
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

/// What the kernel says about a process, for telling a live lease holder
/// from a pid reused since.
enum ProcessFacts {
    static func info(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// Seconds since 1970 when the process started.
    static func startTime(of pid: pid_t) -> Double? {
        guard let info = info(pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }

    static func isAncestor(_ ancestor: pid_t, of pid: pid_t) -> Bool {
        var current = pid
        while current > 1, let info = info(current) {
            let parent = info.kp_eproc.e_ppid
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }
}
