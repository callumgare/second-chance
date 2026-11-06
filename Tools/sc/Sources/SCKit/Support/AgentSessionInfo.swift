import Foundation

/// What Claude Code shows of an agent session: the name its peers know it by
/// (`second-chance-23`, what `ListAgents` lists) and the title a person sees
/// it under (`Testing ./sc session capabilities`).
///
/// Neither is passed to what a session runs, so both are read from Claude
/// Code's own files: the name from its record of the running session,
/// `<config>/sessions/<pid>.json`, and the title from the session's
/// transcript, `<config>/projects/<project>/<session id>.jsonl`, where a title
/// the person gave it (`custom-title`) wins over the one Claude Code made up
/// (`ai-title`). `<config>` is `CLAUDE_CONFIG_DIR`, or `~/.claude`. Anything
/// missing or unreadable is left out: these only make a lease easier to read.
///
/// A lease records both when it's taken, and whatever shows it looks them up
/// again (`current`), so a session renamed during a long run is shown by its
/// new title. Only the Mac the session runs on has its files, so every `--on`
/// command sends that Mac's sessions along in `SC_AGENT_SESSIONS`
/// (`snapshot`), as a test Mac showing a lease has none of them. That costs a
/// few milliseconds: only the end of each transcript is read.
struct AgentSessionInfo: Codable, Equatable, Sendable {
    var name: String?
    var title: String?

    /// How much of the end of a transcript is searched for its title: the
    /// first, then the second if that has none. Claude Code writes the title
    /// again as the session goes on (both kinds), so it's within a few tens of
    /// KB of the end; a transcript runs to tens of MB, never read whole.
    static let titleTailBytes = [64 << 10, 1 << 20]

    static func lookUp(pid: Int32?, sessionID: String?,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentSessionInfo {
        let config = configDirectory(environment: environment)
        var info = AgentSessionInfo()
        if let pid { info.name = name(pid: pid, sessionID: sessionID, config: config) }
        if let sessionID { info.title = title(sessionID: sessionID, config: config) }
        return info
    }

    static let snapshotVariable = "SC_AGENT_SESSIONS"

    /// Every session running on this Mac for this user, by session id.
    static func snapshot(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: AgentSessionInfo] {
        let config = configDirectory(environment: environment)
        let sessions = config.appendingPathComponent("sessions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        var found: [String: AgentSessionInfo] = [:]
        for file in names where file.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: sessions.appendingPathComponent(file)),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionID = record["sessionId"] as? String,
                  let pid = (record["pid"] as? NSNumber)?.int32Value else { continue }
            let info = lookUp(pid: pid, sessionID: sessionID, environment: environment)
            if info.name != nil || info.title != nil { found[sessionID] = info }
        }
        return found
    }

    /// Base64 of the snapshot's JSON: one shell-safe word for the remote command line.
    static func encodeSnapshot(_ snapshot: [String: AgentSessionInfo]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return ((try? encoder.encode(snapshot)) ?? Data()).base64EncodedString()
    }

    static func decodeSnapshot(_ encoded: String) -> [String: AgentSessionInfo] {
        guard let data = Data(base64Encoded: encoded),
              let snapshot = try? JSONDecoder().decode([String: AgentSessionInfo].self, from: data) else { return [:] }
        return snapshot
    }

    /// The session's name and title now: read from its files when it runs
    /// on this Mac as this user, else from the sessions `--on` sent along;
    /// nil when neither knows it (shown without `--on` on another Mac, or the
    /// session has ended), so the recorded ones stand.
    static func current(of holder: ScreenLease.Holder, thisHost: String = ScreenLease.shortHostName(),
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentSessionInfo? {
        guard let sessionID = holder.sessionID else { return nil }
        if holder.host == thisHost, holder.user == NSUserName() {
            let info = lookUp(pid: holder.agentPID, sessionID: sessionID, environment: environment)
            if info.name != nil || info.title != nil { return info }
        }
        return environment[snapshotVariable].flatMap { decodeSnapshot($0)[sessionID] }
    }

    static func configDirectory(environment: [String: String]) -> URL {
        if let path = environment["CLAUDE_CONFIG_DIR"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    /// The session's name, if the record under its pid is this session's
    /// (a pid is reused once a session has ended).
    static func name(pid: Int32, sessionID: String?, config: URL) -> String? {
        let file = config.appendingPathComponent("sessions/\(pid).json")
        guard let data = try? Data(contentsOf: file),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let sessionID, let recorded = record["sessionId"] as? String, recorded != sessionID { return nil }
        return nonEmpty(record["name"] as? String)
    }

    static func title(sessionID: String, config: URL) -> String? {
        let projects = config.appendingPathComponent("projects")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        for folder in folders {
            let transcript = projects.appendingPathComponent(folder).appendingPathComponent("\(sessionID).jsonl")
            guard let handle = try? FileHandle(forReadingFrom: transcript) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            for length in titleTailBytes {
                let start = size > UInt64(length) ? size - UInt64(length) : 0
                guard (try? handle.seek(toOffset: start)) != nil, let tail = try? handle.readToEnd() else { return nil }
                if let found = title(inTranscript: tail) { return found }
                if start == 0 { break }
            }
            return nil
        }
        return nil
    }

    /// The latest title a person gave, or else the latest Claude Code made.
    static func title(inTranscript data: Data) -> String? {
        guard data.range(of: Data("-title\"".utf8)) != nil else { return nil }
        var custom: String?
        var generated: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Only the title lines are parsed: a transcript is mostly the conversation.
            guard line.count < 4096, let text = String(data: line, encoding: .utf8), text.contains("-title\"") else { continue }
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch entry["type"] as? String {
            case "custom-title": custom = nonEmpty(entry["customTitle"] as? String) ?? custom
            case "ai-title": generated = nonEmpty(entry["aiTitle"] as? String) ?? generated
            default: break
            }
        }
        return custom ?? generated
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
