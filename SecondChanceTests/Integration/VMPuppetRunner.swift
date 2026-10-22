//
//  VMPuppetRunner.swift
//  SecondChanceTests
//
//  The launch-and-quit in a tart VM instead of on this Mac
//  (`sc test integration --vm <name>`): the game is built here as usual, then
//  the wrapp and WrappPuppeteer are copied into the VM and WrappPuppeteer runs
//  there, in its GUI session. Its log and the game's come back through
//  `log show` and are judged exactly as a local run's are
//  (`AppPuppetRunner.judge`). docs/testing.md#testing-in-a-vm has the why.

import Foundation
import Testing
@testable import SecondChance

/// The VM `sc` prepared: running, reachable over SSH, someone logged in at
/// its console, Rosetta installed (`TestVM` in Tools/sc).
struct VMTarget: Sendable {
    let name: String
    /// `user@ip`.
    let sshTarget: String
    let sshKey: String?

    /// Set when `sc test integration --vm` runs the suite: it passes
    /// `TEST_RUNNER_VM_*`, and xcodebuild drops the prefix.
    static let current: VMTarget? = {
        let env = ProcessInfo.processInfo.environment
        guard let target = env["VM_SSH_TARGET"], !target.isEmpty else { return nil }
        return VMTarget(name: env["VM_NAME"] ?? "vm", sshTarget: target,
                        sshKey: env["VM_SSH_KEY"].flatMap { $0.isEmpty ? nil : $0 })
    }()

    /// Why this game can't be launch-tested in a VM, if it can't. A VM's
    /// GPU has Metal but no hardware OpenGL, so Wine's Direct3D gets no
    /// rendering context and the game quits before drawing anything: a
    /// result about the VM, not the game. The build was still tested.
    static func launchSkipReason(wrappURL: URL) -> String? {
        guard let vm = current else { return nil }
        let engine = WrappInfo.gameEngine(at: wrappURL) ?? ""
        guard engine == "wine" || engine.hasPrefix("wine-"),
              let exe = WrappInfo.gameExe(at: wrappURL),
              GameGraphicsAPI(exeAt: exe) == .direct3D else { return nil }
        return "draws with Direct3D, which a VM can't render (no hardware OpenGL in VM \(vm.name)); the build was tested, the launch wasn't"
    }

    /// Why nothing launched on this Mac's screen could come to the front,
    /// if so. With a VM the game launches there, so this Mac's screen
    /// doesn't matter.
    static func screenBlockedReason() -> String? {
        current == nil ? ScreenState.blockedReason() : nil
    }

    /// A VM cloned from an image shares its host key with every other clone
    /// and gets a new address each boot, so known_hosts would only get in the
    /// way.
    var sshOptions: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15",
         "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR"]
            + (sshKey.map { ["-i", $0] } ?? [])
    }
}

enum VMPuppetRunner {
    /// What a VM run failed at, before there was a result to judge.
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Where Second Chance keeps the Steam sign-in, relative to the home
    /// directory, in the VM as here (`SteamSessionStore.defaultRoot`).
    static let steamStoreInHome = "Library/Application Support/SecondChance/Steam"

    /// Launch `wrappURL` with WrappPuppeteer in `vm` and judge the result as
    /// `AppPuppetRunner` judges a local run. Returns WrappPuppeteer's exit code.
    static func run(in vm: VMTarget, puppeteer: URL, wrappURL: URL, gameSlug: String, timeout: TimeInterval,
                    requiredHelpers: [InProcessHelperReport.Helper]) async throws -> Int32 {
        // The SSH work blocks, so it's off the test's task; what it brings
        // back is recorded and judged here, where attachments reach the test.
        let outcome = try await Task.detached(priority: .userInitiated) {
            try runBlocking(in: vm, puppeteer: puppeteer, wrappURL: wrappURL, timeout: timeout)
        }.value
        let label = "vm-\(vm.name)"
        if let diagnostics = outcome.diagnostics {
            Attachment.record(diagnostics, named: "diagnostics-\(label)-\(gameSlug).tar")
        }
        for note in outcome.notes { console(note) }
        try AppPuppetRunner.judge(puppeteerLog: outcome.puppeteerLog, gameLog: outcome.gameLog, exitCode: outcome.exitCode,
                                  gameSlug: gameSlug, attemptLabel: label, requiredHelpers: requiredHelpers)
        return outcome.exitCode
    }

    /// What a run in the VM brought back.
    private struct Outcome: Sendable {
        let exitCode: Int32
        let puppeteerLog: Data
        let gameLog: Data
        let diagnostics: Data?
        var notes: [String] = []
    }

    private static func runBlocking(in vm: VMTarget, puppeteer: URL, wrappURL: URL, timeout: TimeInterval) throws -> Outcome {
        let id = UUID().uuidString.prefix(8).lowercased()
        let job = "/tmp/sc-vm-test-\(id)"
        let agent = "au.gare.callum.second-chance.vm-test.\(id)"
        let shell = VMShell(vm: vm)

        // A run stopped partway (the test host killed) leaves its job, and
        // whatever it was running, in the VM.
        _ = try? shell.run(cleanupScript(agentPattern: "au.gare.callum.second-chance.vm-test.", jobPattern: "/tmp/sc-vm-tes[t]-"))

        let usesSteam = (WrappInfo.gameEngine(at: wrappURL) ?? "").hasPrefix("wine-steam")
        defer {
            if usesSteam { _ = try? shell.run("rm -rf \(quoted("~/" + steamStoreInHome))") }
            _ = try? shell.run(cleanupScript(agentPattern: agent, jobPattern: job))
        }

        console("Copying \(wrappURL.lastPathComponent) and WrappPuppeteer into VM \(vm.name)…")
        try shell.check("mkdir -p \(job)/wrapp")
        try shell.send(puppeteer, to: job)
        try shell.send(wrappURL, to: "\(job)/wrapp")
        if usesSteam { try copySteamSignIn(into: shell) }

        let bundleID = (try? WrappInfo.readPlist(at: wrappURL))?["CFBundleIdentifier"] as? String ?? ""
        let slug = (try? WrappInfo.gameSlug(at: wrappURL)) ?? nil
        try shell.write(jobScript(job: job, bundleID: bundleID, gameSlug: slug ?? "", timeout: timeout), to: "\(job)/run.sh")
        try shell.write(agentPlist(label: agent, script: "\(job)/run.sh"), to: "\(job)/agent.plist")
        try shell.check("chmod +x \(job)/run.sh && launchctl bootstrap gui/$(id -u) \(job)/agent.plist")
        console("Launching \(wrappURL.lastPathComponent) in VM \(vm.name)…")

        // WrappPuppeteer bounds every one of its own waits; this only stops a
        // run that hangs outright, or a VM that went away.
        let deadline = Date().addingTimeInterval(2 * 60 * 60)
        var exitCode: Int32?
        while exitCode == nil {
            if let status = try? shell.run("cat \(job)/status 2>/dev/null"), status.status == 0,
               let code = Int32(status.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                exitCode = code
                break
            }
            guard Date() < deadline else { throw Failure(description: "WrappPuppeteer didn't finish in VM \(vm.name) within 2 hours") }
            Thread.sleep(forTimeInterval: 5)
        }

        var outcome = Outcome(
            exitCode: exitCode ?? 1,
            puppeteerLog: Data(SystemLogReader.compactLines(fromNDJSON: try shell.read("\(job)/puppeteer.ndjson")).utf8),
            gameLog: Data(SystemLogReader.compactLines(fromNDJSON: try shell.read("\(job)/game.ndjson")).utf8),
            diagnostics: (try? shell.read("\(job)/diagnostics.tar")).flatMap { $0.isEmpty ? nil : $0 }
        )
        if usesSteam, let note = saveSteamSignInBack(from: shell) { outcome.notes.append(note) }
        return outcome
    }

    // MARK: - The job in the VM

    /// Run in the VM's GUI session as a one-off LaunchAgent: WrappPuppeteer
    /// needs a WindowServer, which an SSH session doesn't have.
    static func jobScript(job: String, bundleID: String, gameSlug: String, timeout: TimeInterval) -> String {
        """
        #!/bin/bash
        # Written by VMPuppetRunner (SecondChanceTests): one game's launch-and-quit.
        J=\(job)
        wrapp=$(ls -d "$J"/wrapp/*.app | head -1)
        # WrappPuppeteer expects the save warning; a leftover "don't show again" hides it.
        rm -f "$HOME/Library/Application Support/\(bundleID)/dont-show-save-warning"
        # macOS checks a freshly copied app the first time it's opened, the
        # whole bundle, which on a VM's disk can take minutes: longer than
        # WrappPuppeteer waits for the save warning. Open it once the same way,
        # through LaunchServices, and quit it as soon as it's running — when its
        # launch log appears — so that's over before WrappPuppeteer's clock starts.
        logs="$HOME/Library/Logs/SecondChance/\(gameSlug)"
        open -g -j -n "$wrapp"
        for i in $(seq 1 900); do
          [ -n "$(find "$logs" -name 'launch-*.log' -newer "$J/run.sh" 2>/dev/null)" ] && break
          sleep 1
        done
        pkill -TERM -f "$wrapp/Contents/"
        for i in $(seq 1 30); do pgrep -f "$wrapp/Contents/" >/dev/null || break; sleep 1; done
        pkill -9 -f "$wrapp/Contents/"
        start=$(date -v-5S "+%Y-%m-%d %H:%M:%S")
        "$J/WrappPuppeteer.app/Contents/MacOS/WrappPuppeteer" "$wrapp" --timeout \(Int(timeout)) > "$J/puppeteer.out" 2>&1 &
        pid=$!
        wait "$pid"
        code=$?
        log show --start "$start" --predicate "processIdentifier == $pid AND subsystem BEGINSWITH 'au.gare.callum.second-chance'" --style ndjson --info --debug > "$J/puppeteer.ndjson" 2>/dev/null
        log show --start "$start" --predicate "subsystem == 'au.gare.callum.second-chance.WrappTemplate'" --style ndjson --info --debug > "$J/game.ndjson" 2>/dev/null
        bundles=$(find "$HOME/Library/Logs/SecondChance/diagnostics" -mindepth 1 -maxdepth 1 -type d -newer "$J/run.sh" 2>/dev/null)
        [ -n "$bundles" ] && tar -cf "$J/diagnostics.tar" $bundles 2>/dev/null
        echo "$code" > "$J/status"
        """
    }

    static func agentPlist(label: String, script: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(label)</string>
        <key>ProgramArguments</key><array><string>/bin/bash</string><string>\(script)</string></array>
        <key>RunAtLoad</key><true/>
        <key>LimitLoadToSessionType</key><string>Aqua</string>
        </dict></plist>
        """
    }

    /// Stop LaunchAgents whose labels contain `agentPattern`, kill what's
    /// running from paths matching `jobPattern`, and remove those paths. A
    /// pattern for pkill names itself with a bracket (`tes[t]`) so this
    /// script's own command line doesn't match.
    static func cleanupScript(agentPattern: String, jobPattern: String) -> String {
        let removable = jobPattern.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        let pkillPattern = jobPattern.contains("[") ? jobPattern : String(jobPattern.dropLast()) + "[\(jobPattern.last.map(String.init) ?? "")]"
        return """
        for l in $(launchctl list | awk '{print $3}' | grep -F '\(agentPattern)'); do launchctl bootout gui/$(id -u)/$l 2>/dev/null; done
        pkill -9 -f '\(pkillPattern)' 2>/dev/null
        rm -rf \(removable)*
        true
        """
    }

    // MARK: - Steam

    /// A Steam wrapp launched through Steam signs in with the shared sign-in
    /// (docs/steam.md), which lives on this Mac: copy it in for the run.
    private static func copySteamSignIn(into shell: VMShell) throws {
        let store = SteamSessionStore()
        guard store.hasSession else {
            throw Failure(description: "This game launches through Steam, and there's no saved Steam sign-in on this Mac to copy into the VM. Build a Steam game from the app first.")
        }
        let root = "~/" + steamStoreInHome
        try shell.check("mkdir -p \(quoted(root)) && chmod 700 \(quoted(root)) && rm -rf \(quoted(root + "/session"))")
        try shell.send(store.sessionDir, to: root)
        try shell.check("chmod 700 \(quoted(root + "/session")) && touch \(quoted(root + "/session.lock"))")
    }

    /// Steam can replace the token when it signs in. If the VM's Steam saved
    /// a newer session than this Mac's, bring it back through
    /// `SteamSessionStore.capture`, with its lock and newer-wins rule, so the
    /// copy here isn't left holding a token Steam has retired.
    /// Returns what to tell the person running the tests, if anything.
    private static func saveSteamSignInBack(from shell: VMShell) -> String? {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sc-vm-steam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            try shell.receive("~/" + steamStoreInHome + "/session", into: temp)
            let vmStore = SteamSessionStore(root: temp)
            let local = SteamSessionStore()
            let token = SteamSessionStore.tokenFile
            guard vmStore.hasSession,
                  try Data(contentsOf: vmStore.sessionDir.appendingPathComponent(token))
                    != Data(contentsOf: local.sessionDir.appendingPathComponent(token)) else { return nil }
            // capture reads a prefix: the session's files where a prefix has
            // them, and AutoLoginUser in user.reg.
            let prefix = temp.appendingPathComponent("prefix")
            for file in SteamSessionStore.files {
                let target = prefix.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: vmStore.sessionDir.appendingPathComponent(file), to: target)
            }
            let fragment = try String(contentsOf: vmStore.registryFragment, encoding: .utf8)
            guard let line = fragment.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("\"\(SteamSessionStore.registryValue)\"=") }) else {
                return "The VM's Steam saved a new sign-in, but it names no account, so it wasn't brought back"
            }
            try "\(SteamSessionStore.registrySection) 0\n\(line)\n".write(to: prefix.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
            let result = try local.capture(from: prefix, signedIn: true)
            return "The VM's Steam replaced its token; brought the new sign-in back: \(result)"
        } catch {
            return "Couldn't check the VM's Steam sign-in against this Mac's: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    /// `path` quoted for a shell, leaving a leading `~/` for it to expand.
    static func quoted(_ path: String) -> String {
        if path.hasPrefix("~/") { return "~/" + shellQuote(String(path.dropFirst(2))) }
        return shellQuote(path)
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func console(_ message: String) {
        print("[VM] \(message)")
        fflush(stdout)
    }
}

/// SSH to the VM, and tar over it (tar keeps extended attributes, which hold
/// the code signatures of a wrapp's non-Mach-O files).
struct VMShell {
    let vm: VMTarget

    struct Result {
        let status: Int32
        let output: String
    }

    /// Run `command` in the VM through bash, whatever its login shell.
    @discardableResult
    func run(_ command: String, input: Pipe? = nil) throws -> Result {
        let (status, data) = try ssh("/bin/bash -c " + VMPuppetRunner.shellQuote(command), input: input)
        return Result(status: status, output: String(decoding: data, as: UTF8.self))
    }

    func check(_ command: String) throws {
        let result = try run(command)
        guard result.status == 0 else {
            throw VMPuppetRunner.Failure(description: "In VM \(vm.name), `\(command)` failed (\(result.status)): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// A file's contents, empty when it doesn't exist.
    func read(_ path: String) throws -> Data {
        try ssh("cat \(VMPuppetRunner.quoted(path)) 2>/dev/null").output
    }

    func write(_ text: String, to path: String) throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        DispatchQueue.global().async {
            writer.write(Data(text.utf8))
            try? writer.close()
        }
        let result = try run("cat > \(VMPuppetRunner.quoted(path))", input: pipe)
        guard result.status == 0 else {
            throw VMPuppetRunner.Failure(description: "Couldn't write \(path) in VM \(vm.name): \(result.output)")
        }
    }

    /// Copy `item` (a file or directory) into the VM's directory `remoteDir`.
    func send(_ item: URL, to remoteDir: String) throws {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", "-", "-C", item.deletingLastPathComponent().path, item.lastPathComponent]
        let pipe = Pipe()
        tar.standardOutput = pipe
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        let result = try run("tar -xf - -C \(VMPuppetRunner.quoted(remoteDir))", input: pipe)
        tar.waitUntilExit()
        guard tar.terminationStatus == 0, result.status == 0 else {
            throw VMPuppetRunner.Failure(description: "Copying \(item.lastPathComponent) into VM \(vm.name) failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Copy the VM's `remotePath` (a file or directory) into `localDir`.
    func receive(_ remotePath: String, into localDir: URL) throws {
        let parent = (remotePath as NSString).deletingLastPathComponent
        let name = (remotePath as NSString).lastPathComponent
        let archive = try ssh("tar -cf - -C \(VMPuppetRunner.quoted(parent)) \(VMPuppetRunner.quoted(name))")
        guard archive.status == 0 else {
            throw VMPuppetRunner.Failure(description: "Copying \(remotePath) out of VM \(vm.name) failed")
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", "-", "-C", localDir.path]
        let pipe = Pipe()
        tar.standardInput = pipe
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        pipe.fileHandleForWriting.write(archive.output)
        try pipe.fileHandleForWriting.close()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            throw VMPuppetRunner.Failure(description: "Unpacking \(remotePath) from VM \(vm.name) failed")
        }
    }

    /// Run a remote command line; stdout and stderr together.
    private func ssh(_ command: String, input: Pipe? = nil) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = vm.sshOptions + [vm.sshTarget, command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input ?? FileHandle.nullDevice
        try process.run()
        // Drain before waiting: a full pipe would block ssh, and the wait with it.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
