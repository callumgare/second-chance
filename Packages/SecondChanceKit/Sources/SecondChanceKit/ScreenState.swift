//
//  ScreenState.swift
//  Shared
//
//  Whether an app can come to the front at all. Nothing can while the screen
//  is locked — loginwindow is the frontmost app then — or while the display
//  is asleep, so a test that launches a game and waits for it to take focus
//  would only time out, with nothing saying why.

import CoreGraphics
import Foundation

nonisolated public enum ScreenState {
    /// Why no app can come to the front now, or nil if one can. Also nil in a
    /// process with no GUI session to ask about, which can't tell.
    public static func blockedReason() -> String? {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            return "the screen is locked"
        }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            return "the display is asleep"
        }
        return nil
    }
}
