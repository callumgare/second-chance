import Foundation

/// The files a command writes, and how to take its writes back out again
/// without taking anything else with them.
///
/// Writing the original back would also throw away whatever else changed in
/// the file since it was read — an edit made in Xcode while a release build
/// ran, say. So a file that changed after the command last wrote it gets a
/// three-way merge instead (`git merge-file`): the step from what the command
/// wrote back to the original is applied to what is there now, which keeps
/// the other changes. When the two touch the same lines, the file is left as
/// it is and reported, rather than guessed at.
actor FileRollback {
    struct Outcome: Sendable {
        /// Files whose changes were taken back out.
        var undone: [URL] = []
        /// Files that couldn't be put back, with why.
        var failed: [(url: URL, reason: String)] = []
    }

    private struct Entry {
        /// nil when the file didn't exist.
        let original: Data?
        /// What the command last wrote; nil until it writes.
        var written: Data?
    }

    private var entries: [URL: Entry] = [:]
    private let order: [URL]

    /// Snapshot `urls` as they are now, before anything writes to them.
    init(_ urls: [URL]) {
        order = urls
        for url in urls {
            entries[url] = Entry(original: try? Data(contentsOf: url))
        }
    }

    /// Write `string` to `url`, one of the files given to `init`, and
    /// remember it as what this command wrote.
    func write(_ string: String, to url: URL) throws {
        guard entries[url] != nil else {
            throw SCError("FileRollback isn't tracking \(url.path).")
        }
        let data = Data(string.utf8)
        try data.write(to: url, options: .atomic)
        entries[url]?.written = data
    }

    /// Take out the command's writes, leaving every other change in place.
    func restore() async -> Outcome {
        var outcome = Outcome()
        for url in order {
            guard let entry = entries[url], let written = entry.written else { continue }
            let current = try? Data(contentsOf: url)
            do {
                if current == entry.original {
                    // Already as it was.
                } else if current == written {
                    if let original = entry.original {
                        try original.write(to: url, options: .atomic)
                    } else {
                        try FileManager.default.removeItem(at: url)
                    }
                    outcome.undone.append(url)
                } else if let current, let original = entry.original {
                    if let merged = try await Self.merge(current: current, written: written, original: original) {
                        try merged.write(to: url, options: .atomic)
                        outcome.undone.append(url)
                    } else {
                        outcome.failed.append((url, "changed since it was written, on the same lines — left as it is"))
                    }
                } else if current == nil {
                    outcome.failed.append((url, "removed since it was written — left removed"))
                } else {
                    // Created by the command, then changed by someone else:
                    // removing it would take their changes too.
                    outcome.failed.append((url, "created by this run and changed since — left in place"))
                }
            } catch {
                outcome.failed.append((url, error.localizedDescription))
            }
        }
        entries = entries.mapValues { Entry(original: $0.original) }
        return outcome
    }

    /// `current` with the change from `written` to `original` applied, or
    /// nil when that conflicts with what else changed.
    static func merge(current: Data, written: Data, original: Data) async throws -> Data? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-rollback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = [("current", current), ("written", written), ("original", original)].map { name, data in
            (dir.appendingPathComponent(name), data)
        }
        for (url, data) in files { try data.write(to: url) }
        // Exits with the number of conflicts, negative on error.
        let result = try await Proc.collect("git", ["merge-file", "-p", "-q"] + files.map(\.0.path))
        guard result.succeeded else { return nil }
        return Data(result.output.utf8)
    }
}
