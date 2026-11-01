//
//  TestHost.swift
//  SecondChance
//
//  Second Chance is the host the unit and integration tests run in. Under
//  test it keeps nothing a real run would, and opens no main window: each
//  integration-test build has a window of its own. Where `.env` sets
//  SECOND_CHANCE_HIDE_TEST_UI (`sc test` passes it on), it shows no window
//  at all (a log window a test opens is built but kept off screen) and
//  doesn't come to the front, so a test run leaves the Mac free to use;
//  without it the windows show, which helps explain a failure.

import Foundation

nonisolated public enum TestHost {
    /// Whether this process is hosting tests (`xcodebuild test`).
    public static let isRunning = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Whether this test host keeps its windows and Dock icon out of the way.
    public static let hidesUI = isRunning && ProcessInfo.processInfo.environment["SECOND_CHANCE_HIDE_TEST_UI"] == "1"
}
