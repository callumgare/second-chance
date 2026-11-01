//
//  WrappLaunchOptions.swift
//  Shared
//
//  What a wrapp was opened with, read once from its command line. Some of
//  these the wrapp passes to itself when it opens again (`openAgain`); the
//  rest come from `sc` and from someone at a terminal.

import Foundation

nonisolated public struct WrappLaunchOptions: Equatable, Sendable {
    /// Starts a DRM-free game directly rather than through Steam, for this
    /// launch only. Passed by the wrapp to itself when the player picks
    /// "Start Without Steam" after a launch through Steam failed.
    public static let withoutSteamArgument = "--launch-without-steam"
    /// Passed to the copy started afresh after the game had no display
    /// driver, so that a second time shows the error rather than starting it
    /// again.
    public static let afterNoDisplayArgument = "--after-no-display"
    /// Passed by `openAgain`: this copy follows one that is on its way out,
    /// so a copy of the game still running is no reason to stand aside.
    public static let openedAgainArgument = "--opened-again"
    /// Shows the log window and the Debug menu, and keeps the wrapp open
    /// once the game has ended.
    public static let debugArgument = "--debug"
    /// Shows the debug settings before the game starts.
    public static let debugOptionsArgument = "--debug-options"

    public var debugMode: Bool
    public var showsDebugSettings: Bool
    /// Asked for; it applies only to a game that can start without Steam.
    public var withoutSteam: Bool
    public var afterNoDisplay: Bool
    public var openedAgain: Bool

    public init(arguments: [String]) {
        debugMode = arguments.contains(Self.debugArgument)
        showsDebugSettings = arguments.contains(Self.debugOptionsArgument)
        withoutSteam = arguments.contains(Self.withoutSteamArgument)
        afterNoDisplay = arguments.contains(Self.afterNoDisplayArgument)
        openedAgain = arguments.contains(Self.openedAgainArgument)
    }
}
