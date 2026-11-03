//
//  ShellUtilities.swift
//  ProcessKit
//
//  Shell command utilities for formatting and quoting

import Foundation
import WrappLogging

// MARK: - Shell Utilities

/// Characters a shell word can hold unquoted, meaning only themselves.
private nonisolated let shellSafe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@%+,=-")

/// `string` as one shell word: as it is when every character is plain,
/// else in single quotes. Anything else is quoted, by an allow-list rather
/// than a list of what's special, which missed `'`, `#`, tabs and newlines.
public nonisolated func shellQuote(_ string: String) -> String {
    let needsQuoting = string.isEmpty || string.unicodeScalars.contains { !shellSafe.contains($0) }

    if needsQuoting {
        // Escape single quotes by replacing ' with '\''
        let escaped = string.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    return string
}

public nonisolated func formatShellCommand(executable: String, arguments: [String]) -> String {
    let quotedExecutable = shellQuote(executable)
    let quotedArgs = arguments.map { shellQuote($0) }.joined(separator: " ")
    return "\(quotedExecutable) \(quotedArgs)"
}
