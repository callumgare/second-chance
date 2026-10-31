import Foundation

/// The most disk each game's integration build has taken, kept between runs
/// so the next run knows how many builds fit on the disk at once. One JSON
/// object, `{"disk/ghost-dogs": 3500000000, …}`, in `test-results/`, which
/// stays on each Mac (`sc --on` doesn't sync it), as the disk it describes
/// does.
struct IntegrationSizes {
    let url: URL

    init(testResults: URL) {
        url = testResults.appendingPathComponent("integration-sizes.json")
    }

    /// What's recorded, by `source/slug`; empty when nothing is yet.
    func load() -> [String: Int64] {
        guard let data = try? Data(contentsOf: url),
              let sizes = try? JSONDecoder().decode([String: Int64].self, from: data) else { return [:] }
        return sizes
    }

    /// Keep each game's largest size: a build's use varies a little from run
    /// to run, and an estimate that's too small lets too many start.
    func record(_ measured: [String: Int64]) throws {
        guard !measured.isEmpty else { return }
        let merged = load().merging(measured) { max($0, $1) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(merged).write(to: url, options: .atomic)
    }
}
