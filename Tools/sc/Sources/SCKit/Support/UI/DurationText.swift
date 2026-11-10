import Foundation

/// How sc writes a length of time for people to read: `45s`, `46m 38s`,
/// `1h 06m 38s`, to the nearest second. Use it wherever sc shows a duration,
/// rather than formatting seconds by hand: the step spinner, a test run's
/// totals, the integration table's times and the release notes' progress do.
enum DurationText {
    static func text(_ seconds: Double) -> String {
        text(Int(seconds.rounded()))
    }

    static func text(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        let hours = seconds / 3600, minutes = seconds % 3600 / 60, rest = seconds % 60
        if hours > 0 { return "\(hours)h \(twoDigits(minutes))m \(twoDigits(rest))s" }
        if minutes > 0 { return "\(minutes)m \(twoDigits(rest))s" }
        return "\(rest)s"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
