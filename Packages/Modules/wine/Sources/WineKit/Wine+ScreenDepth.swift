//
//  Wine+ScreenDepth.swift
//  WineKit
//
//  The variables that show a Wine session's programs a screen of fewer
//  colours than the Mac's (`--wine.colors`).

import Foundation

nonisolated extension Wine {
    /// What a Wine session runs with to show its programs a screen of
    /// `depth` bits a pixel: the screen depth in-process helper, armed in
    /// every process, as explorer.exe registers the displays the program
    /// takes (docs/wine-in-process-helpers.md#screen-depth). A launch's are
    /// the wrapp's session variables, a build step's its executor's.
    public static func screenDepthVariables(_ depth: Int) -> [String: String] {
        ["SCREEN_DEPTH": String(depth)]
    }
}
