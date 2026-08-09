//
//  DebugUtils.swift
//  SecondChance
//
//  Debugging and diagnostic utilities

import Foundation

class DebugUtils {
    
    /// Trace and log a path from a root directory, showing what exists and what doesn't
    /// Useful for debugging when expected directories are not found
    static func tracePath(from rootPath: URL, to targetPath: URL, fileManager: FileManager = .default) {
        print("   Tracing path from \(rootPath.lastPathComponent) to target: \(targetPath.path)")
        
        // Get relative path components
        let rootComponents = rootPath.pathComponents
        let targetComponents = targetPath.pathComponents
        
        var relativePath = [String]()
        
        // Check if target path is already relative (doesn't contain root components)
        // by looking for common path prefix
        var commonPrefixLength = 0
        for i in 0..<min(rootComponents.count, targetComponents.count) {
            if rootComponents[i] == targetComponents[i] {
                commonPrefixLength = i + 1
            } else {
                break
            }
        }
        
        if commonPrefixLength > 0 {
            // Target contains root path, extract relative part
            relativePath = Array(targetComponents.dropFirst(commonPrefixLength))
        } else {
            // Target is already relative, remove leading "/" if present
            relativePath = targetComponents.filter { $0 != "/" }
        }
        
        // Now trace through each level of the path
        var currentPath = rootPath
        var depth = 0
        let indent = "     "
        
        // Show root directory
        print("   \(String(repeating: indent, count: depth))📁 \(rootPath.lastPathComponent)")
        if let contents = try? fileManager.contentsOfDirectory(atPath: currentPath.path) {
            for item in contents.sorted() {
                let itemPath = currentPath.appendingPathComponent(item)
                var isDir: ObjCBool = false
                fileManager.fileExists(atPath: itemPath.path, isDirectory: &isDir)
                print("   \(String(repeating: indent, count: depth + 1))\(isDir.boolValue ? "📁" : "📄") \(item)")
            }
        }
        
        // Trace through each segment of the expected path
        for (index, segment) in relativePath.enumerated() {
            depth = index + 1
            let nextPath = currentPath.appendingPathComponent(segment)
            
            print("   \(String(repeating: indent, count: depth))Looking for: 📁 \(segment)")
            
            if fileManager.fileExists(atPath: nextPath.path) {
                var isDir: ObjCBool = false
                fileManager.fileExists(atPath: nextPath.path, isDirectory: &isDir)
                
                if isDir.boolValue {
                    print("   \(String(repeating: indent, count: depth))✅ Found directory")
                    
                    // Show contents of this directory
                    if let contents = try? fileManager.contentsOfDirectory(atPath: nextPath.path) {
                        print("   \(String(repeating: indent, count: depth))Contents:")
                        for item in contents.sorted() {
                            let itemPath = nextPath.appendingPathComponent(item)
                            var isSubDir: ObjCBool = false
                            fileManager.fileExists(atPath: itemPath.path, isDirectory: &isSubDir)
                            print("   \(String(repeating: indent, count: depth + 1))\(isSubDir.boolValue ? "📁" : "📄") \(item)")
                        }
                    }
                    currentPath = nextPath
                } else {
                    print("   \(String(repeating: indent, count: depth))❌ Found but is a file, not a directory")
                    break
                }
            } else {
                print("   \(String(repeating: indent, count: depth))❌ Not found")
                print("   \(String(repeating: indent, count: depth))Parent directory contents:")
                if let contents = try? fileManager.contentsOfDirectory(atPath: currentPath.path) {
                    for item in contents.sorted() {
                        let itemPath = currentPath.appendingPathComponent(item)
                        var isDir: ObjCBool = false
                        fileManager.fileExists(atPath: itemPath.path, isDirectory: &isDir)
                        print("   \(String(repeating: indent, count: depth + 1))\(isDir.boolValue ? "📁" : "📄") \(item)")
                    }
                }
                break
            }
        }
    }
}
