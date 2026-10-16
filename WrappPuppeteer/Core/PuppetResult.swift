//
//  PuppetResult.swift
//  WrappPuppeteer
//
//  Result and exit-code types shared by every scenario.

import Foundation

/// Process exit codes. The integration tests read these, so the numbers are a
/// contract — see docs/testing.md.
enum PuppetExitCode: Int32 {
    case passed = 0
    case failed = 1
    case forcedQuit = 2
    case permissionDeniedAccessibility = 3
    case permissionDeniedScreenRecording = 4
    case permissionRelaunchRequiredScreenRecording = 5
}

/// Typed result of running a scenario.
enum PuppetResult {
    case passed
    case forcedQuit
    case failed(String)

    var exitCode: Int32 {
        switch self {
        case .passed: return PuppetExitCode.passed.rawValue
        case .forcedQuit: return PuppetExitCode.forcedQuit.rawValue
        case .failed: return PuppetExitCode.failed.rawValue
        }
    }
}
