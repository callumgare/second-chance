//
//  ModulePaths.swift
//  WrappModules
//
//  What a module's own code says about the paths of its types: where one is
//  in the app, how to name it to a person, and what older settings call it.

import Foundation

/// A module's answers about its path types' paths (docs/wrappfile.md#path-types).
/// Each module's kit has one (`WinePaths` in WineKit); the core and the
/// builders never know a path type's meaning themselves, only ask the module
/// whose type it is. Each process gives the table of the modules it carries
/// (`PathPlaces`) to whatever needs a path placed.
nonisolated public protocol ModulePaths: Sendable {
    /// The path types it answers for: `["wine"]`.
    static var typeNames: [String] { get }

    /// Where `path`, a path of type `type` without its prefix
    /// (`C:/Game/x.exe` of `wine:C:/Game/x.exe`), is in the app whose
    /// `Contents/` is `contents`; nil for one with no place there.
    static func location(of path: String, type: String, in contents: URL) -> URL?

    /// The path as a person reads it in a message ("C:/x.exe, on the game's
    /// Windows hard drive"); nil to show its full form.
    static func describe(_ path: String, type: String) -> String?

    /// The path from the root of the drive it's on (`/Game/x.exe`), which
    /// older settings name a program by; nil for a type with no drives.
    static func legacyProgramPath(of path: String, type: String) -> String?
}

nonisolated extension ModulePaths {
    public static func describe(_ path: String, type: String) -> String? { nil }
    public static func legacyProgramPath(of path: String, type: String) -> String? { nil }
}

/// The modules a process carries, by the path types they answer for: what
/// places a typed path. A bare `/…` is the core's and needs none.
nonisolated public struct PathPlaces: Sendable {
    public let modules: [String: any ModulePaths.Type]

    public init(_ modules: [any ModulePaths.Type]) {
        var byType: [String: any ModulePaths.Type] = [:]
        for module in modules {
            for type in module.typeNames { byType[type] = module }
        }
        self.modules = byType
    }

    /// No module's answers: only the core's bare paths are placed.
    public static let none = PathPlaces([])

    /// `fullForm`'s type and the rest of it (`wine:C:/x` is `wine` and
    /// `C:/x`), for a type one of the modules answers for. A type's name is
    /// never one letter, so a drive (`C:`) is never one.
    public func split(_ fullForm: String) -> (module: any ModulePaths.Type, type: String, rest: String)? {
        guard let colon = fullForm.firstIndex(of: ":") else { return nil }
        let type = String(fullForm[..<colon])
        guard type.count > 1, let module = modules[type] else { return nil }
        return (module, type, String(fullForm[fullForm.index(after: colon)...]))
    }

    /// The path from its drive's root that older settings name a program by.
    public func legacyProgramPath(of fullForm: String) -> String? {
        split(fullForm).flatMap { $0.module.legacyProgramPath(of: $0.rest, type: $0.type) }
    }

    /// The path as a person reads it, else its full form.
    public func describe(_ fullForm: String) -> String {
        split(fullForm).flatMap { $0.module.describe($0.rest, type: $0.type) } ?? fullForm
    }
}
