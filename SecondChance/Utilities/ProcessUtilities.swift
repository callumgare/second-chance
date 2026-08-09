//
//  ProcessUtilities.swift
//  SecondChance
//
//  Utility functions for running shell processes

import Foundation

extension Process {
    /// Run a shell command and return output
    @discardableResult
    static func runShellCommand(_ command: String, arguments: [String] = []) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
