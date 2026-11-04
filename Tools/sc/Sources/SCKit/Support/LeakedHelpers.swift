import Foundation

/// The Safari helper every wrapp launch leaves running, which holds one of
/// the Mac's IOSurface connections for good: after a few full runs a test
/// Mac has none left, and games and installers die at random
/// (docs/testing.md). An integration run ends the ones it started as it
/// finishes: those that weren't there when it began, as its wrapps are
/// gone by then. macOS knows each one's wrapp, but tells only root
/// (`launchctl procinfo`). A run that was stopped can't, so a run also ends
/// what has built up before it starts, if it's more than a Mac in use has.
enum LeakedHelpers {
    static let name = "com.apple.SafariPlatformSupport.Helper"
    /// Fewer than this is a Mac in ordinary use: nothing is ended before a run.
    static let threshold = 20
    /// The newest are left running then, as one may be in use; launchd
    /// starts one again when it's next wanted.
    static let kept = 5

    /// The helpers running now.
    static func running() async -> Set<pid_t> {
        guard let listing = try? await Proc.collect("/bin/ps", ["-axo", "pid=,comm="]), listing.succeeded else { return [] }
        return Set(pids(listing: listing.output))
    }

    /// Before a run: end what earlier runs left, if there are enough to be
    /// leaked ones.
    static func clear(ui: UI) async {
        let ending = toEnd(Array(await running()))
        end(ending, ui: ui)
    }

    /// After a run: end the helpers it started, those not in `before`.
    static func endStarted(since before: Set<pid_t>, ui: UI) async {
        end((await running()).subtracting(before).sorted(), ui: ui)
    }

    private static func end(_ pids: [pid_t], ui: UI) {
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }
        ui.info("Ended \(pids.count) leaked \(name) processes, which hold the Mac's IOSurface connections (docs/testing.md).")
    }

    /// The helpers in `ps -axo pid=,comm=`'s output, by pid.
    static func pids(listing: String) -> [pid_t] {
        listing.split(separator: "\n").compactMap { line -> pid_t? in
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard fields.count == 2, fields[1].hasSuffix("/" + name) || fields[1] == name else { return nil }
            return pid_t(fields[0])
        }.sorted()
    }

    /// Of `helpers`, those to end before a run: all but the newest `kept`
    /// (the highest pids), when there are more than `threshold`.
    static func toEnd(_ helpers: [pid_t]) -> [pid_t] {
        let sorted = helpers.sorted()
        guard sorted.count > threshold else { return [] }
        return Array(sorted.dropLast(kept))
    }
}
