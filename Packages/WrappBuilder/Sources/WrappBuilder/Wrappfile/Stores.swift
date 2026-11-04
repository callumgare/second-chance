//
//  Stores.swift
//  WrappBuilder
//
//  Stores and locks, as `STORE` and `LOCK` declare them: data kept outside
//  any app, which build steps and a launch mount (decision 23 of the
//  builders plan; docs/wrappfile.md#stores).

import Foundation

/// A store: a named folder kept outside any app. The builder never looks
/// inside one.
public nonisolated struct StoreDeclaration: Codable, Sendable, Equatable {
    /// How long it lasts, and so where it lives.
    public enum Retention: String, Codable, Sendable, CaseIterable {
        /// Until someone removes it on purpose: Application Support.
        case keep
        /// Until space is needed: the caches folder.
        case cache
        /// The build or launch that made it: the temporary folder.
        case session
    }

    /// Which apps share it.
    public enum Scope: String, Codable, Sendable, CaseIterable {
        /// One for each app id.
        case app
        /// One for every app.
        case global
    }

    /// Whose it is: a module's id; for a Wrappfile's own, `app` for one of
    /// the app's and `global` for one every Wrappfile declaring it shares.
    public let owner: String
    public let name: String
    public let retention: Retention
    public let scope: Scope
    /// The full name of the lock held while it's used, if it's exclusive.
    public let lock: String?

    public init(owner: String, name: String, retention: Retention = .keep, scope: Scope = .app, lock: String? = nil) {
        self.owner = owner
        self.name = name
        self.retention = retention
        self.scope = scope
        self.lock = lock
    }

    /// `steam:sign-in`, `app:wine-documents`, `global:shared`.
    public var fullName: String { "\(owner):\(name)" }
}

/// A lock, which any store naming it is used under, one user at a time.
public nonisolated struct LockDeclaration: Codable, Sendable, Equatable {
    public let owner: String
    public let name: String
    /// `app`: one lock for each app id; `global`: one for everyone.
    public let scope: StoreDeclaration.Scope

    public init(owner: String, name: String, scope: StoreDeclaration.Scope) {
        self.owner = owner
        self.name = name
        self.scope = scope
    }

    public var fullName: String { "\(owner):\(name)" }
}

/// The stores and locks a Wrappfile, or a module's `stores` files, declare:
/// by full name, with the short names its own files use.
public nonisolated struct StoreDeclarations: Sendable, Equatable {
    public var stores: [String: StoreDeclaration] = [:]
    public var locks: [String: LockDeclaration] = [:]
    /// A Wrappfile's short names, to full names (`wine-documents` to
    /// `app:wine-documents`); a module's are `<id>:<name>` by rule.
    var shortNames: [String: String] = [:]

    public init() {}

    public struct Problem: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    public static let instructions: Set<String> = ["STORE", "LOCK"]

    /// What `instructions` declare: a Wrappfile's (`module` nil) or a
    /// module's. `origin` names the file for what's wrong.
    public static func parse(_ instructions: [Instruction], module: String?, origin: String) throws(Problem) -> StoreDeclarations {
        var declared = StoreDeclarations()
        func owner(_ scope: StoreDeclaration.Scope) -> String { module ?? scope.rawValue }
        func scope(of instruction: Instruction, at: String) throws(Problem) -> StoreDeclaration.Scope {
            guard let text = instruction.option("scope")?.value?.raw else { return .app }
            guard let scope = StoreDeclaration.Scope(rawValue: text) else {
                throw Problem(description: "\(at): --scope=\(text): a store's or lock's scope is app or global")
            }
            return scope
        }
        func name(of instruction: Instruction, at: String) throws(Problem) -> String {
            guard instruction.arguments.count == 1, let name = instruction.arguments.first?.raw,
                  name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
                throw Problem(description: "\(at): \(instruction.keyword) takes one name, in lower case with dashes")
            }
            return name
        }
        // Locks first, so a store may name one declared after it.
        for instruction in instructions where instruction.keyword == "LOCK" {
            let at = "\(origin):\(instruction.line)"
            for option in instruction.options where option.name != "scope" {
                throw Problem(description: "\(at): LOCK takes no --\(option.name)")
            }
            let lock = LockDeclaration(owner: owner(try scope(of: instruction, at: at)), name: try name(of: instruction, at: at),
                                       scope: try scope(of: instruction, at: at))
            guard declared.locks[lock.fullName] == nil, !declared.shortNames.keys.contains("lock \(lock.name)") else {
                throw Problem(description: "\(at): a lock called \(lock.name) is declared already")
            }
            declared.locks[lock.fullName] = lock
            declared.shortNames["lock \(lock.name)"] = lock.fullName
        }
        for instruction in instructions where instruction.keyword == "STORE" {
            let at = "\(origin):\(instruction.line)"
            for option in instruction.options where !["retention", "scope", "exclusive"].contains(option.name) {
                throw Problem(description: "\(at): STORE takes no --\(option.name)")
            }
            let name = try name(of: instruction, at: at)
            let scope = try scope(of: instruction, at: at)
            var retention = StoreDeclaration.Retention.keep
            if let text = instruction.option("retention")?.value?.raw {
                guard let value = StoreDeclaration.Retention(rawValue: text) else {
                    throw Problem(description: "\(at): --retention=\(text): a store is kept (keep), a cache (cache) or one build's or launch's (session)")
                }
                retention = value
            }
            if retention == .session && scope == .global {
                throw Problem(description: "\(at): a session store is one build's or launch's own, so can't be global")
            }
            let fullName = "\(owner(scope)):\(name)"
            guard declared.stores[fullName] == nil, declared.shortNames[name] == nil else {
                throw Problem(description: "\(at): a store called \(name) is declared already")
            }
            var lock: String?
            if let exclusive = instruction.option("exclusive") {
                if let lockName = exclusive.value?.raw {
                    guard let found = declared.shortNames["lock \(lockName)"] else {
                        throw Problem(description: "\(at): --exclusive=\(lockName), but there's no LOCK \(lockName)")
                    }
                    lock = found
                } else {
                    // Its own lock, with its own scope.
                    let own = LockDeclaration(owner: owner(scope), name: name, scope: scope)
                    declared.locks[own.fullName] = own
                    lock = own.fullName
                }
            }
            let store = StoreDeclaration(owner: owner(scope), name: name, retention: retention, scope: scope, lock: lock)
            declared.stores[fullName] = store
            declared.shortNames[name] = fullName
        }
        return declared
    }

    /// A store's full name, as a file of `module`'s (nil for the
    /// Wrappfile) names it: by its full name, or the short name of one of
    /// its owner's.
    public func resolve(_ name: String, module: String?) -> String? {
        if name.contains(":") { return stores[name] == nil ? nil : name }
        if let module { return stores["\(module):\(name)"] == nil ? nil : "\(module):\(name)" }
        return shortNames[name]
    }

    /// Every module's stores and locks: what a plan of modules' stages alone
    /// may use.
    public init(of modules: [ModuleFolder]) {
        for module in modules { merge(module.stores) }
    }

    /// `other`'s added to these: a module's beside the Wrappfile's.
    public mutating func merge(_ other: StoreDeclarations) {
        stores.merge(other.stores) { mine, _ in mine }
        locks.merge(other.locks) { mine, _ in mine }
    }
}
