import Foundation
import Noora

/// A snapshot of a runtime copy, made when a command that needs the build is
/// sent there while a run still goes (docs/dev-cli.md#snapshots): the copy's
/// build, data and sc cloned into `.sc/snapshots/<id>/` (APFS clones, so a
/// second and next to no disk), synced into as the copy would be, and run
/// from. Everything a run keeps (`linkedItems`) is a link back to the copy,
/// so what a run in a snapshot makes outlives it and `attach` finds it.
///
/// A snapshot is removed by the next sync there once no process runs from
/// it. One with changes beyond what was synced into it is kept, and the
/// sync stops with an error naming them: nothing a run makes should land
/// there, so such a change is something to save and a link to add.
enum RuntimeSnapshot {
    static let folder = ".sc/snapshots"
    /// There from the snapshot being made until its sc starts
    /// (`markStarted`), so a sync in between doesn't remove it.
    static let pendingFile = ".sc/snapshot-pending"
    /// Each file's time, size and path once the sync into it finished:
    /// what removing it unchanged would lose nothing of.
    static let manifestFile = ".sc/snapshot-manifest"
    /// How long a snapshot whose sc never started is kept: the sync into it
    /// failed or was stopped. A bound on cleaning up after one, not on
    /// anything a run waits for.
    static let abandonedMinutes = 60

    /// What a snapshot clones from the copy: what a run reads and never
    /// writes.
    static let clonedItems = [Repo.runtimeMarker, "sc", ".sc/sc", ".sc/SC Audio Tap.app", ".sc/SC Audio Tap.stamp",
                              "Bundles", "Modules", "DerivedData/Build"]
    /// What a snapshot links to the copy's own: what a run writes or a
    /// later command reads (`attach` the jobs, `wrapp run` a built wrapp).
    static let linkedItems = [".local", "built-apps", "test-results", "DerivedData/sc-jobs", "DerivedData/sc-logs"]
    /// Linked only when the copy has one: the Mac's settings.
    static let linkedFiles = [".env"]

    /// bash that prints, sorted, each file and link under the current folder
    /// but the snapshot's own bookkeeping, with its time and size. Links
    /// aren't followed, so what's behind a linked item isn't listed.
    static let listing = """
    find . \\( -path ./\(pendingFile) -o -path ./\(manifestFile) \\) -prune -o \\( -type f -o -type l \\) \
    -exec stat -f '%m %z %N' {} + | LC_ALL=C sort
    """

    /// bash run in the copy there that makes a snapshot and prints its path
    /// in the copy.
    static func createScript(copyPath: String) -> String {
        var lines = ["set -e", "cd \(RuntimeCopy.scriptPath(copyPath))",
                     "snap=\(folder)/$(date +%Y%m%d-%H%M%S)-$$",
                     "mkdir -p \"$snap/.sc\" \"$snap/DerivedData\"",
                     "touch \"$snap/\(pendingFile)\""]
        for item in clonedItems {
            lines.append("if [ -e \(Remote.quote(item)) ]; then ditto --clone \(Remote.quote(item)) \"$snap\"/\(Remote.quote(item)); fi")
        }
        for item in linkedItems {
            lines.append("mkdir -p \(Remote.quote(item)) && ln -s \"$PWD\"/\(Remote.quote(item)) \"$snap\"/\(Remote.quote(item))")
        }
        for file in linkedFiles {
            lines.append("if [ -e \(Remote.quote(file)) ]; then ln -s \"$PWD\"/\(Remote.quote(file)) \"$snap\"/\(Remote.quote(file)); fi")
        }
        lines.append("echo \"$snap\"")
        return lines.joined(separator: "\n") + "\n"
    }

    /// bash run in a snapshot once the sync into it finished.
    static let recordScript = "\(listing) > \(manifestFile)\n"

    /// bash run in a snapshot that prints how its files differ from what
    /// was synced into it (`<` as synced, `>` now), at most `shownChanges`
    /// lines, then `more <n>` when there are more.
    static let changesScript = """
    [ -e \(manifestFile) ] || exit 0
    changes=$(diff \(manifestFile) <(\(listing)) | grep '^[<>]')
    [ -n "$changes" ] || exit 0
    printf '%s\\n' "$changes" | head -\(shownChanges)
    count=$(printf '%s\\n' "$changes" | wc -l | tr -d ' ')
    [ "$count" -le \(shownChanges) ] || echo "more $((count - \(shownChanges)))"
    """

    static let shownChanges = 20

    /// Whether `root` is a snapshot of a copy (`folder` in it).
    static func isSnapshot(_ root: URL) -> Bool {
        root.standardizedFileURL.path.contains("/\(folder)/")
    }

    /// What a snapshot that a command has finished in now differs by, read
    /// with `changesScript` here or over ssh. nil when it couldn't be read.
    static func changes(in snapshot: Remote.Target) async -> [String]? {
        let command = "cd \(Remote.shellPath(snapshot.path)) && bash -c \(Remote.quote(changesScript))"
        guard let result = try? await Proc.collect("ssh", ["-T", snapshot.host, command]), result.succeeded else { return nil }
        return result.output.split(separator: "\n").map(String.init)
    }

    static func changes(in root: URL) async -> [String]? {
        guard let result = try? await Proc.collect("/bin/bash", ["-c", changesScript], cwd: root), result.succeeded else { return nil }
        return result.output.split(separator: "\n").map(String.init)
    }

    /// Warn, as a command in a snapshot ends, of what it left there, which
    /// the next sync will stop at (`collect`), so whoever ran it sees it now.
    static func warnOfChanges(in snapshot: Remote.Target, ui: UI) async {
        report(await changes(in: snapshot), at: "\(snapshot.host):\(snapshot.path)",
               remove: "ssh \(snapshot.host) rm -rf \(Remote.shellPath(snapshot.path))", ui: ui)
    }

    static func warnOfChanges(in root: URL, ui: UI) async {
        report(await changes(in: root), at: root.path, remove: "rm -rf \(Remote.quote(root.path))", ui: ui)
    }

    private static func report(_ changes: [String]?, at place: String, remove: String, ui: UI) {
        guard let changes else {
            ui.warning("Couldn't check the snapshot \(place) for changes the run left in it.",
                       next: "The next sync there checks it again, and stops if there are any.")
            return
        }
        guard !changes.isEmpty else { return }
        let lines = changes.map { $0.hasPrefix("more ") ? "  … and \($0.dropFirst(5)) more" : "  \($0)" }
        let message = "The run left changes in its snapshot, \(place), outside the folders it links (< as synced, > now):\n"
            + lines.joined(separator: "\n")
        let next = "The next sync there will stop until it's removed (\(remove)): save what's worth keeping first, then "
            + "make what wrote there write somewhere linked (docs/dev-cli.md#snapshots)."
        ui.warning(TerminalText(stringLiteral: message), next: TerminalText(stringLiteral: next))
    }

    /// bash run in the copy there that removes the snapshots nothing runs
    /// from, and prints `changed <path>` and the differences, indented, for
    /// each it kept because removing it would lose them.
    static func collectScript(copyPath: String) -> String {
        """
        cd \(RuntimeCopy.scriptPath(copyPath)) 2>/dev/null || exit 0
        procs=$(ps -x -o command=)
        for dir in \(folder)/*/; do
          [ -d "$dir" ] || continue
          dir=${dir%/}
          logical="$PWD/$dir"
          physical="$(pwd -P)/$dir"
          case "$procs" in *"$logical/"*|*"$physical/"*) continue ;; esac
          if [ -e "$dir/\(pendingFile)" ] && [ -n "$(find "$dir/\(pendingFile)" -mmin -\(abandonedMinutes))" ]; then continue; fi
          if [ -e "$dir/\(manifestFile)" ]; then
            changes=$(cd "$dir" && diff \(manifestFile) <(\(listing)))
            if [ -n "$changes" ]; then
              echo "changed $physical"
              printf '%s\\n' "$changes" | grep '^[<>]' | head -20 | sed 's/^/  /'
              continue
            fi
          fi
          rm -rf "$dir"
        done
        """
    }

    struct Changed: Equatable {
        var path: String
        var differences: [String]
    }

    static func parseCollect(_ output: String) -> [Changed] {
        var changed: [Changed] = []
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("changed ") {
                changed.append(Changed(path: String(line.dropFirst("changed ".count)), differences: []))
            } else if line.hasPrefix("  "), !changed.isEmpty {
                changed[changed.count - 1].differences.append(String(line.dropFirst(2)))
            }
        }
        return changed
    }

    /// Remove the snapshots nothing runs from in the copy there, or stop
    /// with an error naming those whose changes removing them would lose.
    static func collect(target: Remote.Target) async throws {
        let result = try await Proc.collect("ssh", ["-T", target.host, "bash -c \(Remote.quote(collectScript(copyPath: target.path)))"])
        let changed = parseCollect(result.output)
        guard !changed.isEmpty else { return }
        var hints: [String] = []
        for snapshot in changed {
            hints.append("\(snapshot.path) changed (< as synced, > now):\n" + snapshot.differences.map { "    \($0)" }.joined(separator: "\n"))
        }
        hints.append("Save anything worth keeping from it, then remove it: ssh \(target.host) rm -rf \(Remote.quote(changed[0].path))")
        hints.append("Then find what wrote there, and make it write somewhere a snapshot links (docs/dev-cli.md#snapshots).")
        throw SCError("A snapshot in \(target.host):\(target.path) has changes that removing it would lose, so nothing was synced.",
                      hints: hints)
    }

    /// Make a snapshot of the copy there and return its path there.
    static func create(target: Remote.Target) async throws -> Remote.Target {
        let result = try await Proc.collect("ssh", ["-T", target.host, "bash -c \(Remote.quote(createScript(copyPath: target.path)))"])
        let relative = result.output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard result.succeeded, relative.hasPrefix(folder + "/") else {
            throw SCError("Couldn't make a snapshot of \(target.path) on \(target.host): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return Remote.Target(host: target.host, path: target.path + "/" + relative)
    }

    /// Note what the snapshot holds once synced into, for `collect`.
    static func record(snapshot: Remote.Target) async throws {
        let result = try await Proc.collect("ssh", ["-T", snapshot.host,
                                                    "cd \(Remote.shellPath(snapshot.path)) && bash -c \(Remote.quote(recordScript))"])
        guard result.succeeded else {
            throw SCError("Couldn't note what the snapshot \(snapshot.path) on \(snapshot.host) holds: "
                          + result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Called as sc starts: in a snapshot, its sc is now running from it,
    /// which is what keeps it from being removed.
    static func markStarted(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let root = environment["SC_REPO_ROOT"], !root.isEmpty else { return }
        let pending = URL(fileURLWithPath: root).appendingPathComponent(pendingFile)
        guard FileManager.default.fileExists(atPath: pending.path) else { return }
        do {
            try FileManager.default.removeItem(at: pending)
        } catch {
            TTY.write("Couldn't remove \(pending.path): \(error.localizedDescription)\n")
        }
    }
}
