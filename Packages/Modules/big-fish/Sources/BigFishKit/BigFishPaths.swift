//
//  BigFishPaths.swift
//  BigFishKit
//
//  The big-fish module's answers about its path type, `big-fish:`.

import Foundation
import WineKit
import WrappModules

/// `big-fish:C:/…/LaunchGame.bfg`: what Big Fish's DRM starts, a file on the
/// game's Windows (Wine's) drives, which the wine module places.
public nonisolated enum BigFishPaths: ModulePaths {
    public static let typeNames = ["big-fish"]

    public static func location(of path: String, type: String, in contents: URL) -> URL? {
        WinePaths.location(of: path, type: "wine", in: contents)
    }

    public static func describe(_ path: String, type: String) -> String? { "\(path), which Big Fish's Game Manager starts" }

    public static func legacyProgramPath(of path: String, type: String) -> String? {
        WinePaths.legacyProgramPath(of: path, type: "wine")
    }
}
