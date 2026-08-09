//
//  Logger.swift
//  SecondChance
//
//  Logging utility that works with system logs

import Foundation

/// Simple logging utility that uses NSLog for system log integration
func log(_ message: String) {
    NSLog("%@", message)
}

/// Log with context prefix
func log(_ context: String, _ message: String) {
    NSLog("[%@] %@", context, message)
}
