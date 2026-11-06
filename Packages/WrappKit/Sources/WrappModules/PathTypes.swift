//
//  PathTypes.swift
//  WrappModules
//
//  The path types modules declare: what a path in a Wrappfile is, and
//  which module handles it.

import Foundation

/// A kind of path a module declares in its `module.yaml`
/// (`build: path-types:`, docs/wrappfile.md#path-types): its full form is
/// `<name>:<path>` (`wine:C:/Game.exe`), and the short form it claims, a
/// regular expression on the whole path (`C:/Game.exe`), is rewritten to
/// that when a build is planned. The builder learns them from the modules it
/// loads; it knows no path type of its own.
nonisolated public struct PathType: Sendable, Hashable {
    /// The full form's prefix, without its colon: `wine`.
    public let name: String
    /// Who handles it. Looked up, never written in a Wrappfile.
    public let module: ModuleID
    /// What a path of this type may be.
    public let roles: Set<Role>
    /// The short form it claims, in its roles, in a stage that uses its
    /// module: a regular expression the whole path must match
    /// (`^[A-Za-z]:([/\\].*)?$`). A bare `/…` is always the core's (a place in
    /// the app), so a short form is something more distinctive.
    public let shortForm: String?

    public enum Role: String, Sendable, Hashable, CaseIterable {
        /// A place in the app: what `COPY`, `MOVE`, `REMOVE` and `EDIT` take.
        case location
        /// Something `RUN` or `LAUNCH` starts.
        case program
    }

    public init(name: String, module: ModuleID, roles: Set<Role>, shortForm: String? = nil) {
        self.name = name
        self.module = module
        self.roles = roles
        self.shortForm = shortForm
    }

    /// `path` in this type's full form.
    public func fullForm(_ path: String) -> String { "\(name):\(path)" }

    /// Whether its short form takes `path` in `role`. A pattern that doesn't
    /// compile takes nothing (and is a problem with its module).
    public func claims(_ path: String, as role: Role) -> Bool {
        guard let shortForm, roles.contains(role),
              let pattern = try? NSRegularExpression(pattern: shortForm) else { return false }
        let whole = NSRange(path.startIndex..., in: path)
        return pattern.firstMatch(in: path, options: [.anchored], range: whole).map { $0.range == whole } ?? false
    }
}

/// The path types there are: the modules' a build loaded, or a test's.
nonisolated public struct PathTypeRegistry: Sendable {
    public let types: [PathType]

    public init(_ types: [PathType]) { self.types = types }

    /// The type called `name`.
    public func type(named name: String) -> PathType? { types.first { $0.name == name } }

    /// The type a path is written in full form with, and the rest of it
    /// (`wine:C:/x` is `wine` and `C:/x`); nil for a path that names no
    /// registered type.
    public func split(_ path: String) -> (type: PathType, rest: String)? {
        guard let colon = path.firstIndex(of: ":") else { return nil }
        let prefix = String(path[..<colon])
        // A type's name is never one letter, so `C:` is never one.
        guard prefix.count > 1, let type = type(named: prefix) else { return nil }
        return (type, String(path[path.index(after: colon)...]))
    }

    /// The type that takes `path`, written in a short form, in `role`, in a
    /// stage whose modules are `modules` in the order it used them (those it
    /// was built from first): of the modules whose types' short forms match
    /// it, the one used last. Nil when none does.
    public func claiming(_ path: String, as role: PathType.Role, among modules: [ModuleID]) -> PathType? {
        for module in modules.reversed() {
            if let type = types.first(where: { $0.module == module && $0.claims(path, as: role) }) { return type }
        }
        return nil
    }

    /// The problems with the types themselves: two of one name, a name of
    /// one letter, which would read as a drive, or a short form that isn't
    /// a regular expression.
    public var problems: [String] {
        var problems: [String] = []
        let names = types.map(\.name)
        for name in Set(names) where names.count(where: { $0 == name }) > 1 {
            problems.append("two modules declare the path type \(name):")
        }
        for type in types where type.name.count < 2 {
            problems.append("the \(type.module) module's path type \(type.name): is one letter, which reads as a drive")
        }
        for type in types {
            if let shortForm = type.shortForm, (try? NSRegularExpression(pattern: shortForm)) == nil {
                problems.append("the \(type.module) module's path type \(type.name):'s short form isn't a regular expression: \(shortForm)")
            }
        }
        return problems.sorted()
    }
}
