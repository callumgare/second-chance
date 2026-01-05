//
//  URL+Extensions.swift
//  SecondChance
//
//  URL extensions

import Foundation

extension URL {
    /// Get the relative path from a base URL to this URL
    /// Handles /private symlink resolution properly
    func path(relativeTo base: URL) -> String {
        // Use standardized paths to handle /private symlinks
        let baseURL = base.standardizedFileURL
        let selfURL = self.standardizedFileURL
        
        let baseComponents = baseURL.pathComponents
        let selfComponents = selfURL.pathComponents
        
        // Find common prefix
        var commonCount = 0
        for (baseComp, selfComp) in zip(baseComponents, selfComponents) {
            if baseComp == selfComp {
                commonCount += 1
            } else {
                break
            }
        }
        
        // Get the unique part
        let uniqueComponents = Array(selfComponents[commonCount...])
        return uniqueComponents.joined(separator: "/")
    }
}
