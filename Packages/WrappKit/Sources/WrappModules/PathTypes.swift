//
//  PathTypes.swift
//  WrappModules
//
//  The path types modules register: what a path in a Wrappfile is, and
//  which module handles it.

import Foundation

/// A kind of path a module registers (docs/wrappfile.md#path-types): its
/// full form is `<name>:<path>` (`wine:C:/Game.exe`), and a short form it
/// claims (`C:/Game.exe`) is rewritten to that when a build is planned. The
/// builder checks paths against these, and the wrapp finds a launch's
/// module through them, so the two can't disagree.
nonisolated public struct PathType: Sendable, Hashable {
    /// The full form's prefix, without its colon: `wine`.
    public let name: String
    /// Who handles it. Looked up, never written in a Wrappfile.
    public let module: ModuleID
    /// What a path of this type may be.
    public let roles: Set<Role>
    /// The short form it claims, and in which roles.
    public let shortForm: ShortForm?
    public let shortFormRoles: Set<Role>

    public enum Role: String, Sendable, Hashable, CaseIterable {
        /// A place in the app: what `COPY`, `MOVE`, `REMOVE` and `EDIT` take.
        case location
        /// Something `RUN` or `LAUNCH` starts.
        case program
    }

    public enum ShortForm: Sendable, Hashable {
        /// A drive-letter path: `C:/…`.
        case driveLetter
        /// A folder in the app, `/…/`.
        case folder
    }

    public init(name: String, module: ModuleID, roles: Set<Role>, shortForm: ShortForm? = nil,
                shortFormRoles: Set<Role>? = nil) {
        self.name = name
        self.module = module
        self.roles = roles
        self.shortForm = shortForm
        self.shortFormRoles = shortForm == nil ? [] : (shortFormRoles ?? roles)
    }

    /// `path` in this type's full form.
    public func fullForm(_ path: String) -> String { "\(name):\(path)" }
}

/// The path types there are: the shipped modules', or a test's.
nonisolated public struct PathTypeRegistry: Sendable {
    public let types: [PathType]

    public init(_ types: [PathType]) { self.types = types }

    /// The shipped modules' types.
    public static let shipped = PathTypeRegistry([
        PathType(name: "wine", module: .wine, roles: [.location, .program], shortForm: .driveLetter),
        PathType(name: "dosbox", module: .dosbox, roles: [.location, .program], shortForm: .driveLetter),
        // A program as the folder of the game's data; a location for its
        // saves and settings (`scummvm:saves/`).
        PathType(name: "scummvm", module: .scummvm, roles: [.program, .location], shortForm: .folder,
                 shortFormRoles: [.program]),
        PathType(name: "big-fish", module: .bigFish, roles: [.program]),
        PathType(name: "steam", module: .steam, roles: [.program]),
    ])

    /// The type called `name`.
    public func type(named name: String) -> PathType? { types.first { $0.name == name } }

    /// The type a path is written in full form with, and the rest of it
    /// (`wine:C:/x` is `wine` and `C:/x`); nil for a path that names no
    /// registered type.
    public func split(_ path: String) -> (type: PathType, rest: String)? {
        guard let colon = path.firstIndex(of: ":") else { return nil }
        let prefix = String(path[..<colon])
        // A type's name is never one letter, so `C:` is always a drive.
        guard prefix.count > 1, let type = type(named: prefix) else { return nil }
        return (type, String(path[path.index(after: colon)...]))
    }

    /// The short form `path` is written in, if it's one: `C:/…` a drive
    /// letter, `/…/` a folder.
    public static func shortForm(of path: String) -> PathType.ShortForm? {
        let characters = Array(path)
        if characters.count >= 2, characters[0].isLetter, characters[0].isASCII, characters[1] == ":",
           characters.count == 2 || characters[2] == "/" || characters[2] == "\\" {
            return .driveLetter
        }
        if path.hasPrefix("/") { return .folder }
        return nil
    }

    /// The modules that may handle a path: every type whose module is
    /// among `modules` and that claims `form` in `role`.
    public func claiming(_ form: PathType.ShortForm, as role: PathType.Role, among modules: Set<ModuleID>) -> [PathType] {
        types.filter { $0.shortForm == form && $0.shortFormRoles.contains(role) && modules.contains($0.module) }
    }

    /// The problems with the types themselves: two of one name, or a name
    /// of one letter, which would read as a drive.
    public var problems: [String] {
        var problems: [String] = []
        let names = types.map(\.name)
        for name in Set(names) where names.count(where: { $0 == name }) > 1 {
            problems.append("two modules register the path type \(name):")
        }
        for type in types where type.name.count < 2 {
            problems.append("the \(type.module) module's path type \(type.name): is one letter, which reads as a drive")
        }
        return problems.sorted()
    }
}
