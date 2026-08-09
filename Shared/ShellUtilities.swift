//
//  ShellUtilities.swift
//  Shared
//
//  Shell command utilities for formatting and quoting

import Foundation

// MARK: - Shell Utilities

func shellQuote(_ string: String) -> String {
    // If string contains spaces, special chars, or is empty, quote it
    let needsQuoting = string.isEmpty || string.contains(" ") || string.rangeOfCharacter(from: CharacterSet(charactersIn: "$`\"\\!*?[]{}()<>|;&~")) != nil
    
    if needsQuoting {
        // Escape single quotes by replacing ' with '\''
        let escaped = string.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
    
    return string
}

func formatShellCommand(executable: String, arguments: [String]) -> String {
    let quotedExecutable = shellQuote(executable)
    let quotedArgs = arguments.map { shellQuote($0) }.joined(separator: " ")
    return "\(quotedExecutable) \(quotedArgs)"
}
