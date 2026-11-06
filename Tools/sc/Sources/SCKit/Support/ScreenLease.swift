import Darwin
import Foundation
import SystemConfiguration
import WrappBuilder

/// Who has a screen: one lease per logged-in user, as each has a screen of
/// their own (a test session's, or the console's), taken by every command
/// that opens windows (`GUISession.ensure`), so two runs never fight over it.
///
/// Several agents, each in its own checkout, share a test Mac's screens. A game launched
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
/// gone (it crashed, or the Mac restarted) is stale and is taken over. Work
/// that takes the screen without sc (an engine run by hand, a Peekaboo
/// session, a person at the Mac) takes one by hand with `sc lease take`:
/// that one has no process, and lasts until it's released or expires.
struct ScreenLease: Codable, Equatable, Sendable {
    /// Who asked for the screen, wherever they typed the command.
    struct Holder: Codable, Equatable, Sendable {
        /// A Claude Code session's messaging socket: what peers message it by
        /// (`uds:<socket>`), and what `ListAgents` maps to its name.
        var agentSocket: String?
        var sessionID: String?
        /// The agent's process, on the Mac the command was typed on.
        var agentPID: Int32?
        /// The session's name among its peers (`second-chance-23`) and the
        /// title a person sees it under, read when the lease was asked for
        /// (`AgentSessionInfo`), so a lease names the session wherever it's shown.
        var agentName: String?
        var agentTitle: String?
        /// The Mac, user and checkout the command was typed in.
        var host: String
        var user: String
        var checkout: String
        var branch: String?

        /// The same asker: the same agent session, or, for a person, the same
        /// user on the same Mac.
        func isSame(as other: Holder) -> Bool {
            if let sessionID, let otherID = other.sessionID { return sessionID == otherID }
            return sessionID == nil && other.sessionID == nil && user == other.user && host == other.host
        }
    }

    var holder: Holder
    var purpose: String?
    var command: String
    /// The checkout the run is in, on the leased Mac (for `sc attach`).
    var runCheckout: String
    /// The process holding the lease, and when it started, so a reused pid
    /// isn't mistaken for it.
    /// 0 for a lease taken by hand (`sc lease take`), which has no process.
    var pid: Int32
    var pidStarted: Double
    var started: Date
    /// When a lease taken by hand runs out.
    var expires: Date?

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

    /// Every user's leases on this Mac, one file each, where every user can
    /// read and write them: each logged-in user has a screen of their own (a
    /// test session in the background has one too), and `sc session claim`
    /// leases a test session's screen on its behalf.
    static let sharedDirectory = SharedFolders.leases

    /// The lease on `user`'s screen (this user's unless said), outside any
    /// checkout, so every checkout on the Mac sees it.
    static func file(for user: String = NSUserName(),
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[fileVariable], !path.isEmpty {
            let own = URL(fileURLWithPath: path)
            return user == NSUserName() ? own : own.deletingLastPathComponent().appendingPathComponent("\(user).json")
        }
        return sharedDirectory.appendingPathComponent("\(user).json")
    }

    /// Where a user's lease was kept before test sessions (in their home):
    /// a checkout on an older sc still writes it there, so it's respected too.
    static func legacyFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let path = environment[fileVariable], !path.isEmpty { return nil }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/au.gare.callum.second-chance.sc/screen-lease.json")
    }

    /// A live lease an older sc holds on this user's screen that isn't the asker's.
    static func legacyLease(for user: String, holder: Holder) -> ScreenLease? {
        guard user == NSUserName(), let file = legacyFile(), let lease = read(file), lease.isAlive else { return nil }
        if lease.pid == getpid() || ProcessFacts.isAncestor(lease.pid, of: getpid()) { return nil }
        return lease.isTakenByHand && lease.holder.isSame(as: holder) ? nil : lease
    }

    /// Every lease file in the folder `file()` is in, by user.
    static func all(environment: [String: String] = ProcessInfo.processInfo.environment) -> [(user: String, lease: ScreenLease)] {
        let folder = file(environment: environment).deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().compactMap { name in
            read(folder.appendingPathComponent(name)).map { (String(name.dropLast(5)), $0) }
        }
    }

    // MARK: Who's asking

    /// The holder handed over by `--on` from the Mac it was typed on, or
    /// else this process's own: its agent session, if any, Mac and checkout.
    static func currentHolder(repoRoot: URL, branch: String?,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> Holder {
        if let encoded = environment[holderVariable], let holder = decodeHolder(encoded) { return holder }
        let sessionID = environment["CLAUDE_CODE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }
        let agentPID = environment["CLAUDE_PID"].flatMap { Int32($0) }
        let agent = AgentSessionInfo.lookUp(pid: agentPID, sessionID: sessionID, environment: environment)
        return Holder(
            agentSocket: environment["CLAUDE_CODE_MESSAGING_SOCKET"].flatMap { $0.isEmpty ? nil : $0 },
            sessionID: sessionID,
            agentPID: agentPID,
            agentName: agent.name,
            agentTitle: agent.title,
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

    /// The Mac's name as it's used to reach it: its local host name (`meeka`),
    /// which, unlike `ProcessInfo.hostName`, doesn't change with the network
    /// (that gave a different reverse-DNS name on every call on a Mac with IPv6).
    static func shortHostName() -> String {
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty { return local.lowercased() }
        return shortHostName(ProcessInfo.processInfo.hostName)
    }

    /// The first label of a host name: `meeka`, not `meeka.local`.
    static func shortHostName(_ name: String) -> String {
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
        let screen = SessionPool.screenName()
        let holder = currentHolder(repoRoot: session.repo.root, branch: await branch(of: session.repo.root))
        let lease = ScreenLease(
            holder: holder, purpose: purpose, command: commandLine(Invocation.arguments),
            runCheckout: session.repo.root.path, pid: getpid(), pidStarted: ProcessFacts.startTime(of: getpid()) ?? 0,
            started: Date()
        )
        if let older = legacyLease(for: NSUserName(), holder: holder), policy == .respect {
            throw SCError(older.heldMessage(onHost: screen), hints: older.hints(onHost: screen, askingSession: holder.sessionID),
                          exitCode: heldExitCode)
        }
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
            if existing.isTakenByHand, existing.holder.isSame(as: holder) {
                return  // Taken by hand by whoever is asking now: their own work.
            }
            switch policy {
            case .respect:
                throw SCError(existing.heldMessage(onHost: screen), hints: existing.hints(onHost: screen, askingSession: holder.sessionID),
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

    /// Take the screen by hand for `duration`, for work sc doesn't run. Taking
    /// it again renews it.
    static func take(_ session: Session, policy: Policy, purpose: String?, duration: TimeInterval,
                     user: String = NSUserName()) async throws -> ScreenLease {
        let file = file(for: user)
        let screen = SessionPool.screenName(of: user)
        let holder = currentHolder(repoRoot: session.repo.root, branch: await branch(of: session.repo.root))
        let now = Date()
        let lease = ScreenLease(
            holder: holder, purpose: purpose, command: commandLine(Invocation.arguments),
            runCheckout: session.repo.root.path, pid: 0, pidStarted: 0, started: now, expires: now.addingTimeInterval(duration)
        )
        if let older = legacyLease(for: user, holder: holder), policy == .respect {
            throw SCError(older.heldMessage(onHost: screen), hints: older.hints(onHost: screen, askingSession: holder.sessionID),
                          exitCode: heldExitCode)
        }
        for _ in 0..<3 {
            if try create(lease, at: file) { return lease }
            guard let existing = read(file) else {
                removeIfOld(file)
                continue
            }
            let ours = existing.isTakenByHand && existing.holder.isSame(as: holder)
            if !existing.isAlive || ours || policy == .breakIt {
                if existing.isAlive, !ours {
                    session.ui.warning("Breaking the screen lease: stopping \(existing.summary).")
                    try await stopHolder(existing)
                }
                try? FileManager.default.removeItem(at: file)
                continue
            }
            throw SCError(existing.heldMessage(onHost: screen), hints: existing.hints(onHost: screen, askingSession: holder.sessionID),
                          exitCode: heldExitCode)
        }
        throw SCError("Couldn't take the screen lease at \(file.path): it kept changing under sc.")
    }

    /// Give back a lease taken by hand, if it's the asker's.
    static func releaseTaken(_ session: Session, user: String = NSUserName()) async throws -> Bool {
        let file = file(for: user)
        guard let existing = read(file), existing.isAlive else {
            try? FileManager.default.removeItem(at: file)
            return false
        }
        let holder = currentHolder(repoRoot: session.repo.root, branch: await branch(of: session.repo.root))
        guard existing.isTakenByHand, existing.holder.isSame(as: holder) else {
            throw SCError("The screen lease isn't yours to release: \(existing.who) holds it.",
                          hints: ["See it: sc lease", "Stop it and clear it: sc lease --break"])
        }
        try FileManager.default.removeItem(at: file)
        return true
    }

    enum ExpiryState: Equatable {
        /// Ours, and not yet within the warning.
        case fine
        /// Ours, and expiring within the warning, at this time.
        case expiring(Date)
        /// Not ours any more: released, broken, expired or taken over.
        case gone
    }

    /// Where a lease taken by hand by `holder` stands, `warning` seconds ahead.
    static func expiryState(of lease: ScreenLease?, for holder: Holder, warning: TimeInterval, now: Date = Date()) -> ExpiryState {
        guard let lease, lease.isTakenByHand, lease.holder.isSame(as: holder), let expires = lease.expires, now < expires else {
            return .gone
        }
        return expires.timeIntervalSince(now) <= warning ? .expiring(expires) : .fine
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
        try makeFolder(file.deletingLastPathComponent())
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

    /// The folder, writable by every user when it's the shared one: whoever
    /// makes it first mustn't lock the others out (its parent is world-writable).
    static func makeFolder(_ folder: URL) throws {
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if folder.path.hasPrefix("/Users/Shared/") {
            for path in [folder.deletingLastPathComponent().path, folder.path] { chmod(path, 0o777) }
        }
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
        // A lease taken by hand has no process to stop: breaking it just
        // clears it, and its holder learns from `sc lease`.
        guard !lease.isTakenByHand else { return }
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

    /// The process that took it is still the one running under that pid; or,
    /// taken by hand, it hasn't expired.
    var isAlive: Bool {
        if let expires, Date() >= expires { return false }
        if isTakenByHand { return expires != nil }
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let start = ProcessFacts.startTime(of: pid) else { return false }
        return abs(start - pidStarted) < 1
    }

    /// The holder's agent session's name and title as they were when it took the lease.
    var recordedAgentSession: AgentSessionInfo {
        AgentSessionInfo(name: holder.agentName, title: holder.agentTitle)
    }

    /// The same as they are now (`AgentSessionInfo.current`), where that's known.
    func currentAgentSession(thisHost: String = ScreenLease.shortHostName(),
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentSessionInfo {
        let recorded = recordedAgentSession
        guard let now = AgentSessionInfo.current(of: holder, thisHost: thisHost, environment: environment) else { return recorded }
        return AgentSessionInfo(name: now.name ?? recorded.name, title: now.title ?? recorded.title)
    }

    /// Who holds it, an agent session by its name and title now.
    var who: String { Self.describe(holder, agent: currentAgentSession()) }

    static func describe(_ holder: Holder, agent: AgentSessionInfo) -> String {
        let title = agent.title.map { " (\"\($0)\")" } ?? ""
        if let name = agent.name { return "the agent session \(name)\(title)" }
        if let socket = holder.agentSocket { return "the agent session at \(socket)\(title)" }
        return "\(holder.user) on \(holder.host)"
    }

    var isTakenByHand: Bool { pid == 0 }

    var summary: String {
        "\(who)'s `\(command)`"
    }

    func heldMessage(onHost host: String, now: Date = Date()) -> String {
        var lines: [String]
        if isTakenByHand, let expires {
            lines = ["\(host)'s screen is in use: \(who) took it by hand \(Self.duration(now.timeIntervalSince(started))) ago, "
                + "until \(Self.clock(expires)) (`\(command)`)."]
        } else {
            lines = ["\(host)'s screen is in use: \(who) is running `\(command)`, for \(Self.duration(now.timeIntervalSince(started))) so far."]
        }
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
            let to = currentAgentSession().name.map { "\($0) (uds:\(socket))" } ?? "uds:\(socket) (ListAgents shows its name)"
            hints.append("Ask that session when it'll be done: SendMessage to \(to).")
        }
        // A test session's screen is named <user>@<mac>, as `--on` reaches it.
        let target = host
        if !isTakenByHand { hints.append("Watch it: sc --on \(target):\(runCheckout) attach") }
        hints.append("Go ahead anyway, leaving the lease (windows may clash): add --ignore-screen-lease")
        hints.append(isTakenByHand ? "Clear their lease and take the screen: add --break-screen-lease"
                                   : "Stop that run and take the screen: add --break-screen-lease")
        return hints
    }

    static func clock(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "HH:mm"
        return format.string(from: date)
    }

    /// `30m`, `2h`, `90s`, or a bare number of minutes; at most 8 hours.
    static func parseDuration(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, Double)] = [("h", 3600), ("m", 60), ("s", 1)]
        var seconds: Double?
        for (suffix, scale) in units where trimmed.hasSuffix(suffix) {
            seconds = Double(trimmed.dropLast()).map { $0 * scale }
            break
        }
        if seconds == nil { seconds = Double(trimmed).map { $0 * 60 } }
        guard let seconds, seconds > 0, seconds <= 8 * 3600 else { return nil }
        return seconds
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
