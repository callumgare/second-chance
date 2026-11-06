//
//  ModulePlaces.swift
//  SecondChanceKit
//
//  The shipped modules' answers about their paths, for every app that links
//  this package.

import BigFishKit
import DOSBoxKit
import Foundation
import ScummVMKit
import WineKit
import WrappModules

nonisolated extension PathPlaces {
    /// The shipped modules' kits (docs/wrappfile.md#path-types): where a
    /// `wine:`, `dosbox:`, `scummvm:` or `big-fish:` path is in an app, and
    /// how it reads to a person. The build, the wrapp and WrappPuppeteer all
    /// place paths through it.
    public static let shipped = PathPlaces([WinePaths.self, DOSBoxPaths.self, ScummVMPaths.self, BigFishPaths.self])
}
