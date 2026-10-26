//
//  TestHost.swift
//  SecondChance
//
//  Second Chance is the host the unit and integration tests run in. Under
//  test it shows no window and doesn't come to the front, so a test run
//  leaves the Mac free to use, and it keeps nothing a real run would.

import Foundation

nonisolated enum TestHost {
    /// Whether this process is hosting tests (`xcodebuild test`).
    static let isRunning = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
