import Foundation

/// One record of the JSON-lines progress stream that Second Chance writes
/// (`ProgressFileWriter`) when `SECOND_CHANCE_PROGRESS_PATH` is set, and that
/// the integration tests write when `TEST_RUNNER_PROGRESS_PATH` is.
///
/// `{"event":"stage","stage":"installingGame","text":"Game installing","fraction":0.5}`
/// `{"event":"completed","path":"…/Nancy Drew - X.app"}`
/// `{"event":"failed","message":"…"}`
/// `{"event":"game","slug":"stay-tuned","phase":"launching"}`
/// `{"event":"game","slug":"stay-tuned","phase":"finished","result":"passed","seconds":81.2}`
struct ProgressRecord: Decodable, Equatable, Sendable {
    let event: String
    var stage: String?
    var text: String?
    var fraction: Double?
    var path: String?
    var message: String?
    var slug: String?
    var phase: String?
    var result: String?
    var seconds: Double?
    var puppeteerExit: Int32?

    static func decode(_ line: String) -> ProgressRecord? {
        try? JSONDecoder().decode(ProgressRecord.self, from: Data(line.utf8))
    }

    /// Every record in a progress file, from the start.
    static func all(in url: URL) -> [ProgressRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").compactMap(decode)
    }
}

/// Follows a progress file as it grows, handing over each complete record.
final class ProgressFollower: @unchecked Sendable {
    let url: URL
    private var offset: UInt64 = 0
    private var partial = ""

    init(url: URL) {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    /// Records written since the last call.
    func poll() -> [ProgressRecord] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        offset += UInt64(data.count)
        partial += String(decoding: data, as: UTF8.self)
        var lines = partial.components(separatedBy: "\n")
        partial = lines.removeLast()
        return lines.compactMap(ProgressRecord.decode)
    }

    /// Call `handle` with every record until the task is cancelled.
    func follow(every interval: Duration = .milliseconds(200), _ handle: @escaping @Sendable (ProgressRecord) -> Void) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                for record in poll() { handle(record) }
                try? await Task.sleep(for: interval)
            }
            for record in poll() { handle(record) }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
