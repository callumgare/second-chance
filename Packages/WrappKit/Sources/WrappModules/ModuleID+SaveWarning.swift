//
//  ModuleID+SaveWarning.swift
//  WrappModules
//
//  Generated from each module's `runtime: { save-warning }` by
//  `sc generate`. Don't edit it: change the modules' module.yaml and run
//  that again. A test fails when this file isn't what the data makes.

nonisolated extension ModuleID {
    /// The modules whose programs get the save warning before they start.
    static let showingSaveWarning: Set<ModuleID> = ["wine"]

    /// Whether a program this module runs gets the save warning before it
    /// starts, as its module.yaml says.
    public var showsSaveWarning: Bool { Self.showingSaveWarning.contains(self) }
}
