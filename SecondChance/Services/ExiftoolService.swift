//
//  ExiftoolService.swift
//  SecondChance
//
//  Provides centralized access to bundled exiftool for extracting file metadata

import Foundation

/// Service for extracting metadata from files using exiftool
class ExiftoolService {
    static let shared = ExiftoolService()
    
    let exiftoolPath: String
    private let fileManager = FileManager.default
    
    private init() {
        // Get path to exiftool bundled in app
        let bundleResourcePath = Bundle.main.resourceURL?.appendingPathComponent("exiftool/exiftool")
        print("🔍 Looking for bundled exiftool at: \(bundleResourcePath?.path ?? "nil")")
        
        if let bundlePath = bundleResourcePath?.path, fileManager.fileExists(atPath: bundlePath) {
            exiftoolPath = bundlePath
            print("✅ Found bundled exiftool at: \(bundlePath)")
        } else {
            print("❌ ERROR: Bundled exiftool not found!")
            print("   Bundle.main.resourceURL: \(Bundle.main.resourceURL?.path ?? "nil")")
            print("   Expected at: \(bundleResourcePath?.path ?? "nil")")
            // Use a non-existent path that will fail explicitly
            exiftoolPath = "/EXIFTOOL_NOT_BUNDLED"
        }
    }
    
    /// Extract a specific property from a file using exiftool
    /// - Parameters:
    ///   - filePath: Path to the file to extract metadata from
    ///   - property: The property name to extract (e.g., "Product Name", "Comments")
    /// - Returns: The property value, or nil if not found
    func getFileProperty(_ filePath: String, property: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        process.arguments = ["-\(property)", "-s3", filePath]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // Suppress errors
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !output.isEmpty {
            return output
        }
        
        return nil
    }
    
    /// Extract multiple properties from a file in a single exiftool call
    /// - Parameters:
    ///   - filePath: Path to the file to extract metadata from
    ///   - properties: Array of property names to extract
    /// - Returns: Dictionary of property name to value
    func getFileProperties(_ filePath: String, properties: [String]) throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        
        // Build arguments: -PropertyName -s3 for each property, then the file path
        var args: [String] = []
        for property in properties {
            args.append("-\(property)")
        }
        args.append("-s3")
        args.append(filePath)
        
        process.arguments = args
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return [:]
        }
        
        // Parse output - exiftool with -s3 outputs one value per line
        let lines = output.components(separatedBy: .newlines)
        var result: [String: String] = [:]
        
        for (index, line) in lines.enumerated() {
            if index < properties.count {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result[properties[index]] = trimmed
                }
            }
        }
        
        return result
    }
}
