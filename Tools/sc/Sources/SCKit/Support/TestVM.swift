import Foundation

/// A tart VM the integration tests launch their games in
/// (`sc test integration --vm <name>`). The games are still built on this
/// Mac; the test copies each wrapp and WrappPuppeteer into the VM and runs
/// the launch-and-quit there (`VMPuppetRunner` in the test target).
///
/// sc owns the VM's lifecycle: it starts a stopped VM headless and stops it
/// again afterwards; a VM that was already running is left running. tart
/// finds its VMs through `TART_HOME`, as always.
struct TestVM {
    let name: String
    let session: Session
    var ui: UI { session.ui }

    /// The account to sign in to the VM as: `SC_VM_USER`, else `admin`
    /// (Cirrus Labs' images).
    let user = ProcessInfo.processInfo.environment["SC_VM_USER"].flatMap { $0.isEmpty ? nil : $0 } ?? "admin"
    /// An SSH key for the VM: `SC_VM_SSH_KEY`, else ssh's own defaults.
    let sshKey = ProcessInfo.processInfo.environment["SC_VM_SSH_KEY"].flatMap { $0.isEmpty ? nil : $0 }

    /// A VM ready for the tests: running, reachable, someone logged in at its
    /// console, and Rosetta installed.
    struct Prepared: Sendable {
        let name: String
        /// `user@ip`.
        let target: String
        let sshKey: String?
        /// Whether sc started it, and so should stop it.
        let startedHere: Bool

        /// What the test process needs, as `TEST_RUNNER_` variables (xcodebuild
        /// drops the prefix).
        var testEnvironment: [String: String] {
            var env = ["TEST_RUNNER_VM_NAME": name, "TEST_RUNNER_VM_SSH_TARGET": target]
            if let sshKey { env["TEST_RUNNER_VM_SSH_KEY"] = sshKey }
            return env
        }
    }

    func prepare() async throws -> Prepared {
        try await ui.progressStep("Preparing VM \(name)", success: "VM \(name) is ready", failure: "VM \(name) isn't ready") { update in
            let startedHere = try await startIfStopped(update: update)
            do {
                update("Preparing VM \(name) — waiting for its address")
                let ip = try await address()
                let target = "\(user)@\(ip)"
                update("Preparing VM \(name) — connecting to \(target)")
                try await waitForSSH(target)
                try await checkConsole(target)
                update("Preparing VM \(name) — checking Rosetta")
                try await ensureRosetta(target)
                return Prepared(name: name, target: target, sshKey: sshKey, startedHere: startedHere)
            } catch {
                if startedHere { _ = try? await Proc.collect("tart", ["stop", name]) }
                throw error
            }
        }
    }

    /// Stop the VM if sc started it.
    func finish(_ prepared: Prepared) async {
        guard prepared.startedHere else { return }
        do {
            let result = try await Proc.collect("tart", ["stop", name])
            if result.status != 0 {
                ui.warning("Couldn't stop VM \(name): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))", next: "Stop it with: tart stop \(name)")
            }
        } catch {
            ui.warning("Couldn't stop VM \(name): \(error.localizedDescription)", next: "Stop it with: tart stop \(name)")
        }
    }

    // MARK: - Steps

    /// Start the VM headless unless it's running. Returns whether it started it.
    private func startIfStopped(update: @Sendable (String) -> Void) async throws -> Bool {
        if try await state() == "running" { return false }
        update("Preparing VM \(name) — starting it")
        // Detached, so the VM outlives this call; `finish` stops it. `tart
        // run` only prints if it fails to start, which the wait for an
        // address then reports.
        let result = try await Proc.collect("/bin/sh", ["-c", "nohup tart run \"$0\" --no-graphics >/dev/null 2>&1 &", name])
        guard result.status == 0 else {
            throw SCError("Couldn't start VM \(name): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return true
    }

    /// The VM's state from `tart list`.
    private func state() async throws -> String {
        let result: Proc.Collected
        do {
            result = try await Proc.collect("tart", ["list", "--format", "json", "--source", "local"])
        } catch {
            throw SCError("--vm needs tart, which isn't installed.", hints: ["brew install cirruslabs/cli/tart", "docs/testing.md#testing-in-a-vm"])
        }
        guard result.status == 0 else {
            throw SCError("`tart list` failed: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let vms = Self.parseList(result.output)
        guard let state = vms[name] else {
            throw SCError("There's no tart VM named \(name).",
                          hints: ["VMs: \(vms.keys.sorted().joined(separator: ", "))",
                                  "TART_HOME says where tart keeps them.",
                                  "docs/testing.md#testing-in-a-vm"])
        }
        return state
    }

    /// Name → state, from `tart list --format json`.
    static func parseList(_ json: String) -> [String: String] {
        guard let entries = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [:] }
        var states: [String: String] = [:]
        for entry in entries {
            guard let name = entry["Name"] as? String else { continue }
            states[name] = (entry["State"] as? String) ?? ((entry["Running"] as? Bool) == true ? "running" : "stopped")
        }
        return states
    }

    private func address() async throws -> String {
        let result = try await Proc.collect("tart", ["ip", name, "--wait", "180"])
        let ip = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !ip.isEmpty else {
            throw SCError("VM \(name) didn't get a network address within 3 minutes.",
                          hints: ["Start it with a window to see why: tart run \(name)"])
        }
        return ip
    }

    /// For every ssh to the VM. A VM cloned from an image shares its host key
    /// with every other clone and gets a new address each boot, so
    /// known_hosts would only get in the way.
    var sshOptions: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=no",
         "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR"]
            + (sshKey.map { ["-i", $0] } ?? [])
    }

    private func ssh(_ target: String, _ command: String) async throws -> Proc.Collected {
        try await Proc.collect("/usr/bin/ssh", sshOptions + [target, command])
    }

    /// sshd can lag the address by a few seconds after a boot. Retries while
    /// the connection is refused, up to 90 s; a refused key fails at once.
    private func waitForSSH(_ target: String) async throws {
        let deadline = Date().addingTimeInterval(90)
        var last = ""
        while true {
            let result = try await ssh(target, "true")
            if result.status == 0 { return }
            last = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            if last.contains("Permission denied") || Date() > deadline { break }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        throw SCError("Can't sign in to VM \(name) as \(target) over SSH: \(last)",
                      hints: ["The tests sign in with a key, never a password: copy yours in with `ssh-copy-id \(target)`, or name one with SC_VM_SSH_KEY.",
                              "SC_VM_USER picks the account (default: admin)."])
    }

    /// WrappPuppeteer runs in the VM's GUI session, so someone must be logged
    /// in at its console, with the screen unlocked. Just after a boot, SSH
    /// answers before automatic login has started that session, so this
    /// waits for it, up to 2 minutes.
    private func checkConsole(_ target: String) async throws {
        let command = "launchctl print gui/$(id -u) >/dev/null 2>&1 || echo no-session; ioreg -n Root -d1 -a | grep -q CGSSessionScreenIsLocked && echo locked; true"
        let deadline = Date().addingTimeInterval(120)
        var result = try await ssh(target, command)
        while result.output.contains("no-session"), Date() < deadline {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            result = try await ssh(target, command)
        }
        if result.output.contains("no-session") {
            throw SCError("Nobody is logged in at VM \(name)'s console as \(user), so games can't open windows there.",
                          hints: ["Turn on automatic login for \(user) in the VM (Cirrus Labs' images have it on)."])
        }
        if result.output.contains("locked") {
            throw SCError("VM \(name)'s screen is locked, so games can't come to the front there.",
                          hints: ["Unlock it (tart run \(name) shows its screen), and turn off its screen lock."])
        }
    }

    /// The wrapps' Wine is x86_64, so it runs under Rosetta, which a fresh
    /// macOS install doesn't have.
    private func ensureRosetta(_ target: String) async throws {
        if try await ssh(target, "/usr/bin/arch -x86_64 /usr/bin/true").status == 0 { return }
        let install = try await ssh(target, "sudo -n /usr/sbin/softwareupdate --install-rosetta --agree-to-license")
        guard install.status == 0 else {
            throw SCError("Rosetta isn't installed in VM \(name), and installing it failed: \(install.error.trimmingCharacters(in: .whitespacesAndNewlines))",
                          hints: ["Install it in the VM: softwareupdate --install-rosetta --agree-to-license"])
        }
    }
}
