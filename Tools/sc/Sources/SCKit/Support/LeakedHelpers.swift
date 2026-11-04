import Foundation

/// The Safari helper every wrapp launch leaves running, which holds one of
/// the Mac's IOSurface connections for good: after a few full runs a test
/// Mac has none left, and games and installers die at random
/// (docs/testing.md). Ended before an integration run, so runs don't add up.
enum LeakedHelpers {
    static let name = "com.apple.SafariPlatformSupport.Helper"
    /// Fewer than this is a Mac in ordinary use: nothing is ended.
    static let threshold = 20
    /// The newest are left running, as one may be in use; launchd starts
    /// one again when it's next wanted.
    static let kept = 5

    /// End the leaked helpers, if there are enough to be leaked ones.
    static func clear(ui: UI) async {
        guard let listing = try? await Proc.collect("/bin/ps", ["-axo", "pid=,comm="]), listing.succeeded else { return }
        let ending = toEnd(listing: listing.output)
        guard !ending.isEmpty else { return }
        for pid in ending { kill(pid, SIGTERM) }
        ui.info("Ended \(ending.count) leaked \(name) processes, which hold the Mac's IOSurface connections (docs/testing.md).")
    }

    /// From `ps -axo pid=,comm=`: the helpers to end, all but the newest
    /// `kept` (the highest pids), when there are more than `threshold`.
    static func toEnd(listing: String) -> [pid_t] {
        let helpers = listing.split(separator: "\n").compactMap { line -> pid_t? in
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard fields.count == 2, fields[1].hasSuffix("/" + name) || fields[1] == name else { return nil }
            return pid_t(fields[0])
        }.sorted()
        guard helpers.count > threshold else { return [] }
        return Array(helpers.dropLast(kept))
    }
}
