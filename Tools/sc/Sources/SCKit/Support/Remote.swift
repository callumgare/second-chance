import Foundation
import WrappBuilder

/// `--on <host>[:<path>]`: run the same command on another Mac.
///
/// 1. rsync this repo there (everything but per-machine output and settings:
///    `.git`, `.env`, `built-apps`, `test-results`, `tmp`, sc's own `.build`,
///    and all of `DerivedData` but `Build/Products`);
/// 2. `ssh` in and run `./sc` with the same arguments, minus `--on`, plus an
///    explicit `--logs` so the output looks the way it would have here.
///
/// Output stays on the remote Mac: test results and reports are written to
/// its `test-results/`, not copied back.
///
/// On the remote Mac, commands that open windows re-run themselves in its GUI
/// session as usual — someone must be logged in at its console. That run
/// outlives a dropped connection; `attach` (which skips the sync) follows it
/// again, and the sync refuses to run over it in the meantime.
enum Remote {
    struct Target: Equatable {
        let host: String
        /// The repo's path there; `~/` paths are relative to the remote home.
        let path: String
    }

    /// Take `--on` out of the arguments (only before a `--` terminator).
    static func extractTarget(from arguments: [String]) -> (target: String?, rest: [String]) {
        var rest: [String] = []
        var target: String?
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--" {
                rest += arguments[index...]
                break
            }
            if arg == "--on", index + 1 < arguments.count {
                target = arguments[index + 1]
                index += 2
                continue
            }
            if arg.hasPrefix("--on=") {
                target = String(arg.dropFirst("--on=".count))
                index += 1
                continue
            }
            rest.append(arg)
            index += 1
        }
        return (target, rest)
    }

    /// Split `host[:path]`, defaulting the path to this repo's path relative
    /// to the home directory (or the same absolute path when it isn't under it).
    static func parse(_ target: String, localRoot: URL, home: String = NSHomeDirectory()) -> Target {
        if let colon = target.firstIndex(of: ":") {
            return Target(host: String(target[..<colon]), path: String(target[target.index(after: colon)...]))
        }
        let root = localRoot.standardizedFileURL.path
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        let path = root.hasPrefix(homePrefix) ? "~/" + root.dropFirst(homePrefix.count) : root
        return Target(host: target, path: path)
    }

    /// The remote command line, written to read the same in bash, zsh and
    /// fish (whichever is the remote login shell): single-quoted words, `~/`
    /// left unquoted so it expands. The holder of any screen lease the
    /// command takes there goes with it through `env` (ssh passes no
    /// environment), as one base64 word.
    /// The agent sessions running here go too, so a lease one of them holds
    /// there is shown by its title now (`AgentSessionInfo.current`).
    /// `executable`, a binary sent beside a run still going there
    /// (`RuntimeCopy.versionPath`), runs instead of the copy's `./sc`, told
    /// the copy is its root as the launcher would.
    static func remoteCommand(path: String, arguments: [String], leaseHolder: ScreenLease.Holder? = nil,
                              agentSessions: [String: AgentSessionInfo] = [:], executable: String? = nil) -> String {
        let dir = path.hasPrefix("~/") ? "~/" + quote(String(path.dropFirst(2))) : quote(path)
        var variables: [String] = []
        if let leaseHolder { variables.append("\(ScreenLease.holderVariable)=\(ScreenLease.encodeHolder(leaseHolder))") }
        if !agentSessions.isEmpty {
            variables.append("\(AgentSessionInfo.snapshotVariable)=\(AgentSessionInfo.encodeSnapshot(agentSessions))")
        }
        // "$PWD" reads the same in bash, zsh and fish.
        if executable != nil { variables.append("SC_REPO_ROOT=\"$PWD\"") }
        let env = variables.isEmpty ? "" : "env " + variables.joined(separator: " ") + " "
        let program = executable.map(quote) ?? "./sc"
        return "cd \(dir) && \(env)\(program) " + arguments.map(quote).joined(separator: " ")
    }

    /// A checkout's path for a remote command line: quoted, but with `~/`
    /// left bare so the shell there expands it.
    static func shellPath(_ path: String) -> String {
        path.hasPrefix("~/") ? "~/" + quote(String(path.dropFirst(2))) : quote(path)
    }

    static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What every runtime copy holds besides the build: the data sc reads
    /// there (program bundles' manifests and needles, modules), which the
    /// app also carries inside itself.
    static let dataFolders = ["Bundles", "Modules"]

    /// Commands that need no build there: they claim, lease, list or clean.
    static let buildlessCommands: Set = ["session", "lease", "attach", "clean", "installers", "setup"]

    /// The rsync rules for the main sync. Only what's named is sent; the
    /// rest of a copy there (an older full checkout's files, its own
    /// `built-apps`, `test-results`, logs and jobs) is left as it is, since
    /// rsync neither sends nor deletes what's excluded. Of the build, the
    /// Debug products and the test build's `.xctestrun`: the rest of
    /// `DerivedData` records this checkout's absolute path, and Release's
    /// products are gigabytes nothing there runs.
    static func syncFilters(for arguments: [String]) -> [String] {
        var rules = ["--exclude", ".DS_Store"]
        for folder in dataFolders { rules += ["--include", "/\(folder)/"] }
        if !buildlessCommands.contains(arguments.first ?? "") {
            rules += ["--include", "/DerivedData/", "--include", "/DerivedData/Build/",
                      "--exclude", "/DerivedData/Build/Products/Release/",
                      "--include", "/DerivedData/Build/Products/",
                      "--exclude", "/DerivedData/Build/*", "--exclude", "/DerivedData/*"]
        }
        return rules + ["--exclude", "/*"]
    }

    /// The paths under `.local` (the porting workspaces) a command names, as
    /// they read from the checkout's root: an argument, or the value of an
    /// `--option=value`, that is such a path and exists. Only those are
    /// sent: `.local` holds gigabytes no other command reads.
    static func localPaths(in arguments: [String], root: URL, cwd: URL) -> [String] {
        let local = root.appendingPathComponent(".local").standardizedFileURL.path + "/"
        var found: [String] = []
        for argument in arguments {
            var candidates = [argument]
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                candidates.append(String(argument[argument.index(after: equals)...]))
            }
            for candidate in candidates where !candidate.isEmpty && !candidate.hasPrefix("-") {
                let url = candidate.hasPrefix("/") ? URL(fileURLWithPath: candidate) : cwd.appendingPathComponent(candidate)
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(local), FileManager.default.fileExists(atPath: path) else { continue }
                let relative = String(path.dropFirst(root.standardizedFileURL.path.count + 1))
                if !found.contains(relative) { found.append(relative) }
            }
        }
        return found
    }

    /// Commands that read no installers.
    static let lightCommands: Set = ["puppet", "session", "lease", "attach", "lint", "generate", "clean", "setup", "installers"]

    /// Whether the command may read installers: not a light command, and
    /// not one whose every source (`--source` for a test run, `--from` for
    /// a build) gets its game some other way, so a download test into a
    /// test session doesn't wait on tens of gigabytes of disc images.
    static func readsInstallers(_ arguments: [String]) -> Bool {
        if lightCommands.contains(arguments.first ?? "") { return false }
        let fetched: Set = ["download", "steam", "big-fish", "big-fish-trial"]
        var values: [String] = []
        for (index, argument) in arguments.enumerated() {
            for flag in ["--source", "--from"] {
                if argument == flag, index + 1 < arguments.count { values.append(arguments[index + 1]) }
                if argument.hasPrefix(flag + "=") { values.append(String(argument.dropFirst(flag.count + 1))) }
            }
        }
        let sources = values.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
        return sources.isEmpty || !sources.allSatisfy(fetched.contains)
    }

    /// The installers' own sync, for commands that read them: this Mac's
    /// store into the other Mac's, which is at the usual place there
    /// (`InstallersStore.defaultRoot`). Links go as links, so a disc image
    /// linked to one of its alternatives is linked the same there. Never
    /// `--delete`: the other Mac may hold installers this one doesn't have.
    /// No `-t` or `-E`, and files are compared by size: the store's files
    /// belong to whoever put them there, and another user is let write them
    /// but not set their times or extended attributes, which made the
    /// receiver quit (`utimensat: Permission denied`) and the sync fail.
    /// Finder's `.DS_Store` stays behind, as in the main sync.
    /// One at a time on each Mac: the receiving rsync waits for a lock
    /// (`lockf`, on a file every user can open), since test users' syncs
    /// share one store, and two writing the same files at once each read
    /// the other's half-written copy as their basis.
    static func installersSync(from store: URL, host: String) -> [String] {
        ["-rl", "--size-only", "--exclude", ".DS_Store", "--rsync-path=\(installersReceiver)",
         store.path + "/", "\(host):\(InstallersStore.defaultRoot.path)/"]
    }

    static let installersSyncLock = "/tmp/second-chance-installers-sync.lock"
    static let installersReceiver = "/usr/bin/lockf -k \(installersSyncLock) /usr/bin/rsync"

    /// Why a sync that stopped partway failed, and what to do, by rsync's
    /// exit status. What was sent is there and the rest isn't, so the copy's
    /// build may be half-copied until a sync completes.
    static func syncFailure(host: String, rawTarget: String, arguments: [String], status: Int32) -> SCError {
        let hint: String
        switch status {
        case 255, 12, 10, 35, 30:
            // ssh failed, or the connection broke or timed out.
            hint = "The connection to \(host) failed or dropped (rsync's exit \(status)). Check `ssh \(host) true` works, then run it again."
        case 24:
            hint = "Files here vanished while they were being copied: a build here. Run it again once that's done."
        case 23:
            hint = "Some files couldn't be copied (rsync's exit 23): files here that changed while being copied, or ones \(host) "
                + "couldn't write. The sync's log in DerivedData/sc-logs says which."
        default:
            hint = "rsync exited \(status). The sync's log in DerivedData/sc-logs says why."
        }
        return SCError("Copying the build to \(host) stopped partway, so nothing was run there.", hints: [hint], exitCode: status)
    }

    /// Commands that need the sources, so make no sense run on a copy.
    static func needsSources(_ arguments: [String]) -> Bool {
        let first = arguments.first ?? ""
        let second = arguments.dropFirst().first ?? ""
        return ["lint", "generate", "release", "worktree", "module", "bundle"].contains(first)
            || (first == "app" && second == "build")
            || (first == "test" && ["unit", "all"].contains(second))
    }

    /// What to build here before running there, when the command would
    /// build first and wasn't told not to: a test build for `test`, else
    /// the app. nil when it takes no `--skip-app-build` or was given it.
    enum LocalBuild { case app, tests }
    static func localBuild(for arguments: [String]) -> LocalBuild? {
        guard !arguments.contains("--skip-app-build") else { return nil }
        let end = arguments.firstIndex(of: "--") ?? arguments.endIndex
        let probe = Array(arguments[..<end]) + ["--skip-app-build"] + Array(arguments[end...])
        guard (try? SC.parseAsRoot(probe)) != nil else { return nil }
        return arguments.first == "test" ? .tests : .app
    }

    /// The arguments with `--skip-app-build` added (before any `--`), once
    /// the build has been made here.
    static func skippingAppBuild(_ arguments: [String]) -> [String] {
        let end = arguments.firstIndex(of: "--") ?? arguments.endIndex
        return Array(arguments[..<end]) + ["--skip-app-build"] + Array(arguments[end...])
    }

    /// Whether the command needs this repo synced there first. `attach`
    /// follows a run already going, so it must not touch the checkout, and
    /// `lease` only reads (or breaks) the screen lease.
    static func syncs(_ arguments: [String]) -> Bool {
        !["attach", "lease"].contains(arguments.first)
            && !(arguments.first == "puppet" && arguments.dropFirst().first != "start")
    }

    /// Lists, one per line, the ids of the GUI-session jobs still running in
    /// the remote checkout (`LaunchAgentJob`). bash, whatever the login shell.
    static func runningJobsCommand(path: String) -> String {
        "cd \(shellPath(path)) 2>/dev/null && bash -c \(quote(runningJobsScript))"
    }

    static let runningJobsScript = """
    for dir in DerivedData/sc-jobs/*/; do
      [ -d "$dir" ] && [ ! -e "$dir/exit-code" ] || continue
      job=$(basename "$dir")
      launchctl print "gui/$(id -u)/\(LaunchAgentJob.labelPrefix)$job" 2>/dev/null | grep -q "pid = " && echo "$job"
    done
    """

    /// What the copy there holds before a sync, in one ssh: the stamp of its
    /// sc (`RuntimeCopy.stamp`), on a line of its own, then the ids of the
    /// jobs still running there, as `runningJobsCommand` lists them.
    static func probeCommand(path: String) -> String {
        let script = "[ -f .sc/sc ] && stat -f '\(probeStampPrefix)%z %m' .sc/sc\n" + runningJobsScript
        return "cd \(shellPath(path)) 2>/dev/null && bash -c \(quote(script))"
    }

    static let probeStampPrefix = "sc-binary "

    struct Probe: Equatable {
        /// The copy's sc's stamp; nil when it has none (no copy yet).
        var stamp: String?
        var runningJobs: [String]
    }

    static func parseProbe(_ output: String) -> Probe {
        var probe = Probe(stamp: nil, runningJobs: [])
        for line in output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if line.hasPrefix(probeStampPrefix) {
                probe.stamp = String(line.dropFirst(probeStampPrefix.count))
            } else {
                probe.runningJobs.append(line)
            }
        }
        return probe
    }

    /// What `--on` sends before running a command there.
    enum SyncPlan: Equatable {
        /// The copy as the command needs it: the build and data too, or for
        /// a buildless command sc and the data.
        case sync
        /// Nothing: a buildless command, and the copy's sc is this one.
        case nothing
        /// A buildless command while a run still goes there: this sc alone,
        /// beside the copy's (`RuntimeCopy.versionPath`), run from there.
        case binaryBeside
        /// A command that needs the build while a run still goes there: a
        /// snapshot of the copy (`RuntimeSnapshot`), synced into and run
        /// from, leaving the run's build alone.
        case snapshot
    }

    /// What to send: a command that needs the build isn't synced over a run
    /// still using it, but into a snapshot beside it. A buildless command
    /// (`buildlessCommands`) reads nothing of the copy's but sc, so one
    /// whose sc is already there sends nothing, and one whose sc differs
    /// gets this sc beside the run's rather than over it.
    static func syncPlan(arguments: [String], probe: Probe, localStamp: String) -> SyncPlan {
        let buildless = buildlessCommands.contains(arguments.first ?? "")
        if buildless, probe.stamp == localStamp { return .nothing }
        guard !probe.runningJobs.isEmpty else { return .sync }
        return buildless ? .binaryBeside : .snapshot
    }

    static func run(on rawTarget: String, arguments: [String]) async throws -> Int32 {
        let terminal = TerminalEnvironment.detect()
        let explicitMode = arguments.firstIndex(of: "--logs").flatMap { arguments.indices.contains($0 + 1) ? LogMode(rawValue: arguments[$0 + 1]) : nil }
        let mode = explicitMode ?? terminal.defaultLogMode
        let repo = try Repo.locate()
        let ui = UI(environment: terminal, mode: mode, logsDir: repo.scLogs)
        Session.active = Session(repo: repo, ui: ui, terminal: terminal, mode: mode)
        let target = parse(rawTarget, localRoot: repo.root)

        if needsSources(arguments) {
            throw SCError("sc \(arguments.prefix(2).joined(separator: " ")) works on the sources, which --on doesn't send.",
                          hints: ["Run it here, without --on."])
        }
        var arguments = arguments
        // Everything is built here; the other Mac or user only runs it.
        if let build = localBuild(for: arguments) {
            let xcode = Xcode(session: Session(repo: repo, ui: ui, terminal: terminal, mode: mode))
            switch build {
            case .tests: try await xcode.buildForTesting()
            case .app: try await xcode.buildApp()
            }
            arguments = skippingAppBuild(arguments)
        }
        let forwarded = Invocation.forwarding(logs: mode, arguments)

        var executable: String?
        var runIn = target
        if syncs(arguments) {
            // Syncing deletes and replaces files under a run still going
            // there (its build in DerivedData, the sc it runs).
            let probe = parseProbe(try await Proc.collect("ssh", ["-T", target.host, probeCommand(path: target.path)]).output)
            let localStamp = try RuntimeCopy.stamp(of: RuntimeCopy.ownExecutable())
            switch syncPlan(arguments: arguments, probe: probe, localStamp: localStamp) {
            case .nothing:
                break
            case .binaryBeside:
                executable = try await sendBinaryBeside(target: target, stamp: localStamp, ui: ui, repo: repo)
            case .sync:
                try await RuntimeSnapshot.collect(target: target)
                try await sync(target: target, rawTarget: rawTarget, arguments: arguments, repo: repo, ui: ui)
            case .snapshot:
                try await RuntimeSnapshot.collect(target: target)
                runIn = try await RuntimeSnapshot.create(target: target)
                ui.detail("A run is still going in \(target.host):\(target.path) (\(probe.runningJobs.joined(separator: ", "))), "
                          + "so this runs in a snapshot of it: \(runIn.path)")
                try await sync(target: runIn, rawTarget: rawTarget, arguments: arguments, repo: repo, ui: ui)
                try await RuntimeSnapshot.record(snapshot: runIn)
            }
        }

        ui.line(ui.format("\(.primary("▸ On \(target.host): sc \(arguments.joined(separator: " "))"))"))
        let holder = ScreenLease.currentHolder(repoRoot: repo.root, branch: await ScreenLease.branch(of: repo.root))
        let command = remoteCommand(path: runIn.path, arguments: forwarded, leaseHolder: holder,
                                    agentSessions: AgentSessionInfo.snapshot(), executable: executable)
        let sshArgs = (terminal.isInteractive ? ["-t"] : ["-T"]) + [target.host, command]
        let status = try await Proc.inheritingTerminal("ssh", sshArgs)
        if runIn != target, status != 255 {
            await RuntimeSnapshot.warnOfChanges(in: runIn, ui: ui)
        }
        if status == 255 {
            // ssh's own failure, not the command's: most often the connection dropped.
            ui.warning("Lost the connection to \(target.host). A command running in its GUI session carries on there.",
                       next: "Pick it up with: sc --on \(rawTarget) attach")
        }
        return status
    }

    /// Send this sc alone beside the copy's, for a buildless command while a
    /// run still goes there (`SyncPlan.binaryBeside`), and return its path
    /// in the copy. It stays until the next sync, as a command it runs may
    /// re-run it in the GUI session or copy it.
    static func sendBinaryBeside(target: Target, stamp: String, ui: UI, repo: Repo) async throws -> String {
        let path = RuntimeCopy.versionPath(stamp: stamp)
        let folder = (path as NSString).deletingLastPathComponent
        let made = try await Proc.collect("ssh", ["-T", target.host, "mkdir -p \(shellPath(target.path + "/" + folder))"])
        guard made.succeeded else {
            throw SCError("Couldn't make \(target.path)/\(folder) on \(target.host): \(made.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let binary = try RuntimeCopy.ownExecutable()
        try await ui.logStep("Send sc to \(target.host)", log: "sync", success: "Sent sc beside the run going on \(target.host)") { sink in
            try await Proc.stream("/usr/bin/rsync", ["-aE", "--rsync-path=/usr/bin/rsync", binary.path, "\(target.host):\(target.path)/\(path)"],
                                  cwd: repo.root) { await sink.line($0) }
        }
        return path
    }

    /// Sync the runtime copy there (`SyncPlan.sync`): nothing runs there.
    static func sync(target: Target, rawTarget: String, arguments: [String], repo: Repo, ui: UI) async throws {
        // macOS's own rsync at both ends, whatever else is on either PATH.
        // Extended attributes must survive (the template's non-Mach-O files
        // keep their code signatures in them), and the two rsyncs disagree
        // on the flag: Apple's (openrsync, or 2.6.9 before macOS 15.4)
        // spells it -E and rejects -X, while rsync 3.x reads -E as
        // --executability and would drop them without a word. Links stay
        // links (never -L, -k): a Wine prefix's z: is a link to /.
        let staging = try RuntimeCopy.stage(in: repo)
        // `puppet audio` there needs the tap, which a copy can't build.
        if arguments.first == "puppet" { try await AudioTapApp.stage(into: staging, repo: repo.root, ui: ui) }
        var rsyncArgs: [String] = ["-aE", "--delete", "--rsync-path=/usr/bin/rsync"] + syncFilters(for: arguments)
        rsyncArgs += ["./", "\(target.host):\(target.path)/"]
        let runtimeArgs = ["-aE", "--rsync-path=/usr/bin/rsync", staging.path + "/", "\(target.host):\(target.path)/"]
        let named = localPaths(in: arguments, root: repo.root, cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let localSyncs = RuntimeCopy.localSyncs(named, root: repo.root, target: target)
        // On this Mac (another user here) the copy is cloned instead, and
        // the installers store is the same one.
        let thisMac = RuntimeCopy.isThisMac(target.host)
        let sendsInstallers = !thisMac && readsInstallers(arguments) && FileManager.default.fileExists(atPath: repo.installers.root.path)
        // The copy there, the folders the named paths go into, and the
        // Mac's installers store, made first.
        // Binaries sent beside a run (`sendBinaryBeside`) go too: none runs now.
        var prepare = "mkdir -p \(shellPath(target.path)) && rm -rf \(shellPath(target.path + "/" + RuntimeCopy.versionsFolder))"
        for path in named {
            let parent = (path as NSString).deletingLastPathComponent
            prepare += " && mkdir -p \(shellPath(target.path + "/" + parent))"
        }
        if sendsInstallers { prepare += " && \(SharedFolders.makeCommand(InstallersStore.defaultRoot))" }
        let prepared = try await Proc.collect("ssh", ["-T", target.host, prepare])
        guard prepared.succeeded else {
            throw SCError("Couldn't make \(target.path) on \(target.host): \(prepared.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if thisMac {
            let script = RuntimeCopy.cloneScript(root: repo.root, staging: staging, named: named, targetPath: target.path,
                                                 products: !buildlessCommands.contains(arguments.first ?? ""))
            try await ui.logStep("Clone to \(target.host)", log: "sync", success: "Cloned to \(target.host):\(target.path)") { sink in
                try await Proc.stream("ssh", ["-T", target.host, "bash -c \(quote(script))"], cwd: repo.root) { await sink.line($0) }
            }
        } else {
            do {
                try await ui.logStep("Sync to \(target.host)", log: "sync", success: "Synced to \(target.host):\(target.path)") { sink in
                    var status = try await Proc.stream("/usr/bin/rsync", rsyncArgs, cwd: repo.root) { await sink.line($0) }
                    if status == 0 {
                        status = try await Proc.stream("/usr/bin/rsync", runtimeArgs, cwd: repo.root) { await sink.line($0) }
                    }
                    for localSync in localSyncs where status == 0 {
                        status = try await Proc.stream("/usr/bin/rsync", localSync, cwd: repo.root) { await sink.line($0) }
                    }
                    guard status == 0, sendsInstallers else { return status }
                    return try await Proc.stream("/usr/bin/rsync", installersSync(from: repo.installers.root, host: target.host), cwd: repo.root) {
                        await sink.line($0)
                    }
                }
            } catch let error as SCError where error.alreadyReported {
                throw syncFailure(host: target.host, rawTarget: rawTarget, arguments: arguments, status: error.exitCode)
            }
        }
    }
}
