//
//  ScummVMPaths.swift
//  ScummVMKit
//
//  The scummvm module's answers about its path type, `scummvm:`.

import Foundation
import WrappModules

/// `scummvm:/SharedSupport/game/`: the folder of a game's data in the app,
/// which ScummVM starts. `scummvm:saves/` and `scummvm:settings/`, where a
/// launch mounts its stores, are ScummVM's own and have no place in the app.
public nonisolated enum ScummVMPaths: ModulePaths {
    public static let typeNames = ["scummvm"]

    public static func location(of path: String, type: String, in contents: URL) -> URL? {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        return contents.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
    }

    public static func describe(_ path: String, type: String) -> String? {
        path.hasPrefix("/") ? "the game's data in the app, \(path) (ScummVM)" : "ScummVM's \(path)"
    }
}
