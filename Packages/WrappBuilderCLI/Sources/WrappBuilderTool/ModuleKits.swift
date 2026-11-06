import BasiliskKit
import BigFishKit
import DOSBoxKit
import ScummVMKit
import WineKit
import WrappBuilder
import WrappModules

/// The shipped modules' kits this tool carries: where their path types'
/// paths are, and how they're described (`ModulePaths`). `sc` uses the same
/// table.
public nonisolated enum ModuleKits {
    public static let places = PathPlaces([WinePaths.self, DOSBoxPaths.self, ScummVMPaths.self, BigFishPaths.self, BasiliskPaths.self])
}
