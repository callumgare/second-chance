import ArgumentParser
import Foundation

/// When to open the HTML test report.
enum ReportPolicy: String, CaseIterable, ExpressibleByArgument, Sendable {
    /// Only when something failed — a passing run's table says it all.
    case failures
    case always
    case never

    func shouldOpen(failed: Bool) -> Bool {
        switch self {
        case .always: true
        case .never: false
        case .failures: failed
        }
    }
}

/// Reading a run's `.xcresult` and turning it into an HTML report.
enum TestReports {
    struct Summary: Decodable, Sendable {
        struct Failure: Decodable, Sendable {
            let testName: String
            let failureText: String?
        }

        let result: String?
        let totalTestCount: Int?
        let passedTests: Int?
        let failedTests: Int?
        let skippedTests: Int?
        let expectedFailures: Int?
        let startTime: Double?
        let finishTime: Double?
        let testFailures: [Failure]?

        var seconds: Double? {
            guard let startTime, let finishTime else { return nil }
            return finishTime - startTime
        }
    }

    static func summary(of bundle: URL) async -> Summary? {
        guard FileManager.default.fileExists(atPath: bundle.path),
              let result = try? await Proc.collect("/usr/bin/xcrun", ["xcresulttool", "get", "test-results", "summary", "--path", bundle.path, "--format", "json"]),
              result.succeeded else { return nil }
        return try? JSONDecoder().decode(Summary.self, from: Data(result.output.utf8))
    }

    /// Write `test-results/<stamp>/index.html` from one or more result
    /// bundles and return its path.
    static func writeHTML(for bundles: [URL], into dir: URL) async -> URL? {
        let existing = bundles.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty, Proc.which("xchtmlreport") != nil else { return nil }
        guard let result = try? await Proc.collect("xchtmlreport", ["--output", dir.path] + existing.map(\.path)),
              result.succeeded else { return nil }
        let index = dir.appendingPathComponent("index.html")
        return FileManager.default.fileExists(atPath: index.path) ? index : nil
    }
}
