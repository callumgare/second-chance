//
//  FileUtilities.swift
//  SecondChance
//
//  Utility functions for file operations

import Foundation

extension URL {
    /// Check if URL is a directory
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
    
    /// Get file size
    var fileSize: Int64? {
        try? resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) }
    }
}

extension FileManager {
    /// Get the size of a directory recursively
    func sizeOfDirectory(at url: URL) -> Int64 {
        guard let enumerator = enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        
        var totalSize: Int64 = 0
        
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  let isDirectory = resourceValues.isDirectory,
                  !isDirectory,
                  let fileSize = resourceValues.fileSize else {
                continue
            }
            totalSize += Int64(fileSize)
        }
        
        return totalSize
    }
}
