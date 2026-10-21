import Foundation

/// The repo's `.env` (see `.env.example`): local settings that aren't
/// committed — the Sentry DSN the build writes into the app, and the Sentry
/// organisation and project `sc release` uploads debug symbols to.
enum DotEnv {
    /// `KEY=value` lines, as a shell would read them: blank lines and `#`
    /// comments skipped, an optional `export`, optional quotes, last one wins.
    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }

    static func load(_ repo: Repo) -> [String: String] {
        let file = repo.root.appendingPathComponent(".env")
        return (try? String(contentsOf: file, encoding: .utf8)).map(parse) ?? [:]
    }
}
