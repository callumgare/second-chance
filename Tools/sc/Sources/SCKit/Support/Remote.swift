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
    static func remoteCommand(path: String, arguments: [String], leaseHolder: ScreenLease.Holder? = nil) -> String {
        let dir = path.hasPrefix("~/") ? "~/" + quote(String(path.dropFirst(2))) : quote(path)
        let env = leaseHolder.map { "env \(ScreenLease.holderVariable)=\(ScreenLease.encodeHolder($0)) " } ?? ""
        return "cd \(dir) && \(env)./sc " + arguments.map(quote).joined(separator: " ")
    }

    /// A checkout's path for a remote command line: quoted, but with `~/`
    /// left bare so the shell there expands it.
    static func shellPath(_ path: String) -> String {
        path.hasPrefix("~/") ? "~/" + quote(String(path.dropFirst(2))) : quote(path)
    }

    static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Not synced. `.env` holds each Mac's own settings, such as whether
    /// tests hide their windows there. Agents' worktrees are other
    /// checkouts, each with its own build, and come and go mid-sync. A
    /// package's `.build` and `.swiftpm`, like `DerivedData`'s
    /// intermediates, record this checkout's absolute path; `build/` is
    /// release artifacts.
    static let excludes = [
        ".git", ".env", "built-apps", "test-results", "tmp", "Tools/sc/.build", "Tools/sc/.swiftpm", "Tools/sc/.run", ".claude/worktrees",
        "Packages/*/.build", "Packages/*/.swiftpm", "/build", ".DS_Store",
    ]

    /// Local-only folders of gigabytes (the porting workspace) that only
    /// commands building, running or testing games can read. Anything else,
    /// such as driving a puppet session or claiming a test session, leaves
    /// them out: a test user's first sync would otherwise copy them all into
    /// its own home. Left out, they're never deleted there.
    static let heavy = ["/.local"]

    /// Commands that read none of the heavy folders, nor installers.
    static let lightCommands: Set = ["puppet", "session", "lease", "attach", "lint", "generate", "clean", "setup", "installers"]

    static func heavyFilters(for arguments: [String]) -> [String] {
        lightCommands.contains(arguments.first ?? "") ? heavy.flatMap { ["--exclude", $0] } : []
    }

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

    /// Never in the main sync: a checkout's `installers/` from before the
    /// installers store, which `sc installers migrate` empties.
    static let installersExclude = ["--exclude", "/installers"]

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

    /// Before a sync that sends installers: make the checkout there and,
    /// when that Mac has no installers store yet, the store, writable by
    /// every user (as `sc session add` makes it). Then lists what in the store
    /// there is named as installers were before `sc installers migrate`
    /// (`<folder>/disk-1.iso`), for `InstallersStore.isLegacy`.
    static func prepareInstallersCommand(path: String) -> String {
        let dir = shellPath(path)
        let store = quote(InstallersStore.defaultRoot.path)
        return "mkdir -p \(dir) && { [ -d \(store) ] || { mkdir -p \(store) && chmod +a \(quote(SessionPool.everyoneACL)) \(store); }; } "
            + "&& { ls -d \(store)/*/disk-*.iso \(store)/*/her-download* 2>/dev/null || true; }"
    }

    /// Why installers aren't sent when one Mac's store has been migrated and
    /// the other's hasn't: sent, every installer would be there twice, once
    /// in each layout, until that Mac's was migrated.
    static func layoutMismatch(localIsOld: Bool, remoteIsOld: Bool, host: String, rawTarget: String) -> String? {
        guard localIsOld != remoteIsOld else { return nil }
        return localIsOld
            ? "Installers weren't sent to \(host): this Mac's store is in the old layout. Run sc installers migrate here first."
            : "Installers weren't sent to \(host): its store is in the old layout. Run sc --on \(rawTarget) installers migrate first."
    }

    /// Of `DerivedData`, only what was built, `Build/Products`, is synced.
    /// The rest records this checkout's absolute path (Swift packages' state,
    /// the build's intermediates), so a build there in a checkout elsewhere
    /// failed looking for files here; and Xcode's compilation cache is sparse
    /// files tens of gigabytes long that rsync would send in full. rsync
    /// neither sends nor deletes what these leave out, so the remote Mac's
    /// own build state, logs and jobs stay as they are there.
    static let derivedDataFilters = [
        "--include", "/DerivedData/Build/", "--include", "/DerivedData/Build/Products/",
        "--exclude", "/DerivedData/Build/*", "--exclude", "/DerivedData/*",
    ]

    /// The DerivedData rules for a command. Only `--skip-app-build` runs
    /// this Mac's build there, so only then are its products sent. Any other
    /// command builds the app there, where products sent first would only
    /// be in the way, and half-sent whenever something here was rebuilding
    /// them meanwhile.
    static func derivedDataFilters(for arguments: [String]) -> [String] {
        arguments.contains("--skip-app-build") ? derivedDataFilters : ["--exclude", "/DerivedData"]
    }

    /// Why a sync that stopped partway failed, and what to do. What was sent
    /// is there and the rest isn't, so with `--skip-app-build` the other
    /// Mac's app is likely half-copied; its own build won't put that right,
    /// since its build state says the template's set-up is already done.
    static func syncFailure(host: String, rawTarget: String, arguments: [String], status: Int32) -> SCError {
        var hints = ["Files here most likely changed while they were being copied: another build or worktree here. "
            + "Run it again once that's done."]
        if arguments.contains("--skip-app-build") {
            hints.append("\(host)'s copy of the app may be half-copied. Before using it again, clear it and let it build: "
                + "sc --on \(rawTarget) clean build -y, then run without --skip-app-build.")
        }
        return SCError("Copying this checkout to \(host) stopped partway, so nothing was run there.", hints: hints, exitCode: status)
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
        let dir = path.hasPrefix("~/") ? "~/" + quote(String(path.dropFirst(2))) : quote(path)
        let script = """
        for dir in DerivedData/sc-jobs/*/; do
          [ -d "$dir" ] && [ ! -e "$dir/exit-code" ] || continue
          job=$(basename "$dir")
          launchctl print "gui/$(id -u)/\(LaunchAgentJob.labelPrefix)$job" 2>/dev/null | grep -q "pid = " && echo "$job"
        done
        """
        return "cd \(dir) 2>/dev/null && bash -c \(quote(script))"
    }

    static func run(on rawTarget: String, arguments: [String]) async throws -> Int32 {
        let terminal = TerminalEnvironment.detect()
        let explicitMode = arguments.firstIndex(of: "--logs").flatMap { arguments.indices.contains($0 + 1) ? LogMode(rawValue: arguments[$0 + 1]) : nil }
        let mode = explicitMode ?? terminal.defaultLogMode
        let repo = try Repo.locate()
        let ui = UI(environment: terminal, mode: mode, logsDir: repo.scLogs)
        Session.active = Session(repo: repo, ui: ui, terminal: terminal, mode: mode)
        let target = parse(rawTarget, localRoot: repo.root)

        let forwarded = Invocation.forwarding(logs: mode, arguments)

        if syncs(arguments) {
            // Syncing deletes and replaces files under a run still going
            // there (its build in DerivedData, the sc it runs).
            let running = try await Proc.collect("ssh", ["-T", target.host, runningJobsCommand(path: target.path)])
                .output.split(separator: "\n").map(String.init)
            if !running.isEmpty {
                throw SCError("A run is still going in \(target.host):\(target.path) (\(running.joined(separator: ", "))), so it can't be synced over.",
                              hints: ["Follow it with: sc --on \(rawTarget) attach",
                                      "Or stop it: sc --on \(rawTarget) attach --stop"])
            }
            // macOS's own rsync at both ends, whatever else is on either PATH.
            // Extended attributes must survive (the template's non-Mach-O files
            // keep their code signatures in them), and the two rsyncs disagree
            // on the flag: Apple's (openrsync, or 2.6.9 before macOS 15.4)
            // spells it -E and rejects -X, while rsync 3.x reads -E as
            // --executability and would drop them without a word.
            let excludeRules: [String] = excludes.flatMap { ["--exclude", $0] }
            let rsyncArgs: [String] = ["-aE", "--delete", "--rsync-path=/usr/bin/rsync"] + installersExclude + excludeRules
                + derivedDataFilters(for: arguments) + heavyFilters(for: arguments) + ["./", "\(target.host):\(target.path)/"]
            let sendsInstallers = readsInstallers(arguments) && FileManager.default.fileExists(atPath: repo.installers.root.path)
            // The checkout there, and its Mac's store, made first.
            var mismatch: String?
            if sendsInstallers {
                let prepared = try await Proc.collect("ssh", ["-T", target.host, prepareInstallersCommand(path: target.path)])
                guard prepared.succeeded else {
                    throw SCError("Couldn't make \(target.path) on \(target.host): \(prepared.error.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                let remoteListing = prepared.output.split(whereSeparator: \.isNewline).map(String.init)
                mismatch = layoutMismatch(localIsOld: repo.installers.hasLegacyLayout(manifests: repo.manifests),
                                          remoteIsOld: InstallersStore.isLegacy(listing: remoteListing, manifests: repo.manifests),
                                          host: target.host, rawTarget: rawTarget)
            }
            let sendingInstallers = sendsInstallers && mismatch == nil
            do {
                try await ui.logStep("Sync to \(target.host)", log: "sync", success: "Synced to \(target.host):\(target.path)") { sink in
                    let status = try await Proc.stream("/usr/bin/rsync", rsyncArgs, cwd: repo.root) { await sink.line($0) }
                    guard status == 0, sendingInstallers else { return status }
                    return try await Proc.stream("/usr/bin/rsync", installersSync(from: repo.installers.root, host: target.host), cwd: repo.root) {
                        await sink.line($0)
                    }
                }
            } catch let error as SCError where error.alreadyReported {
                throw syncFailure(host: target.host, rawTarget: rawTarget, arguments: arguments, status: error.exitCode)
            }
            if let mismatch { ui.warning("\(mismatch)") }
        }

        ui.line(ui.format("\(.primary("▸ On \(target.host): sc \(arguments.joined(separator: " "))"))"))
        let holder = ScreenLease.currentHolder(repoRoot: repo.root, branch: await ScreenLease.branch(of: repo.root))
        let command = remoteCommand(path: target.path, arguments: forwarded, leaseHolder: holder)
        let sshArgs = (terminal.isInteractive ? ["-t"] : ["-T"]) + [target.host, command]
        let status = try await Proc.inheritingTerminal("ssh", sshArgs)
        if status == 255 {
            // ssh's own failure, not the command's: most often the connection dropped.
            ui.warning("Lost the connection to \(target.host). A command running in its GUI session carries on there.",
                       next: "Pick it up with: sc --on \(rawTarget) attach")
        }
        return status
    }
}
