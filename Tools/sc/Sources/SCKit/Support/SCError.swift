import Foundation

/// An error meant for the person at the terminal: a plain sentence saying what
/// went wrong, and hints saying what to do about it.
struct SCError: Error, CustomStringConvertible {
    var message: String
    var hints: [String]
    var exitCode: Int32
    /// Already shown to the user (e.g. by an expanded failed step); the entry
    /// point only exits with `exitCode`.
    var alreadyReported: Bool

    init(_ message: String, hints: [String] = [], exitCode: Int32 = 1, alreadyReported: Bool = false) {
        self.message = message
        self.hints = hints
        self.exitCode = exitCode
        self.alreadyReported = alreadyReported
    }

    static func reported(exitCode: Int32) -> SCError {
        SCError("", exitCode: exitCode == 0 ? 1 : exitCode, alreadyReported: true)
    }

    var description: String {
        ([message] + hints).joined(separator: "\n")
    }
}
