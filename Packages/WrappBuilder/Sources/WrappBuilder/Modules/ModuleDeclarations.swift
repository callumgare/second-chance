//
//  ModuleDeclarations.swift
//  WrappBuilder
//
//  What a module adds to a build, as its module.yaml's `build:` says:
//  its instructions, the options it adds to the core's, its mount fields.

import Foundation

/// A module's `build:` (docs/modules.md#what-a-module-declares): what the
/// checker and planner know of a module, read from its folder alone, so a
/// module someone adds can declare instructions as a shipped one does.
public nonisolated struct ModuleDeclarations: Sendable, Equatable {
    /// Its instructions, by name (`MOUNT` for `WINE.MOUNT`).
    public var instructions: [String: InstructionSpec] = [:]
    /// Options it adds to core instructions, by instruction, each written
    /// `--<alias>.<option>` in a stage that has the module.
    public var coreOptions: [String: [String: InstructionSpec.OptionKind]] = [:]
    /// What each of those options' values is, where it isn't text.
    public var coreOptionRoles: [String: [String: InstructionSpec.Role]] = [:]
    /// Fields it adds to core mount types, by type, each written
    /// `<alias>.<field>=…` in a `--mount=`.
    public var mountFields: [String: Set<String>] = [:]
    /// Files its Swift provides rather than its folder, which a Wrappfile
    /// names as `module:<id>:/<path>` (the installer module's `autoit`).
    public var providedFiles: Set<String> = []
    /// The instructions `USE` plans in a tree that doesn't have the module
    /// yet, in order (decision 2 of the builders plan).
    public var setup: [String] = []

    public static let none = ModuleDeclarations()

    public init() {}

    /// Its instruction called `name`.
    public func instruction(_ name: String) -> InstructionSpec? { instructions[name] }

    public struct Problem: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// `build:` as YAML gave it, which the schema has already checked.
    /// Decoded by hand, since an instruction's name is a key and kebab-case
    /// decoding would change it.
    public init(_ document: Any?) throws(Problem) {
        guard let build = document as? [String: Any] else { return }
        for (name, value) in build["instructions"] as? [String: Any] ?? [:] {
            instructions[name] = try Self.instruction(name, value as? [String: Any] ?? [:])
        }
        for (instruction, value) in build["core-options"] as? [String: Any] ?? [:] {
            for (option, declared) in value as? [String: Any] ?? [:] {
                let (kind, role) = try Self.option(declared, at: "core-options.\(instruction).\(option)")
                coreOptions[instruction, default: [:]][option] = kind
                if let role { coreOptionRoles[instruction, default: [:]][option] = role }
            }
        }
        for (type, fields) in build["mount-fields"] as? [String: Any] ?? [:] {
            mountFields[type] = Set(fields as? [String] ?? [])
        }
        providedFiles = Set(build["provided-files"] as? [String] ?? [])
        setup = build["setup"] as? [String] ?? []
        for name in setup where instructions[name] == nil {
            throw Problem(description: "setup names \(name), which isn't one of its instructions")
        }
    }

    static func instruction(_ name: String, _ fields: [String: Any]) throws(Problem) -> InstructionSpec {
        var options: [String: InstructionSpec.OptionKind] = [:]
        var roles: [String: InstructionSpec.Role] = [:]
        for (option, declared) in fields["options"] as? [String: Any] ?? [:] {
            let (kind, role) = try Self.option(declared, at: "instructions.\(name).options.\(option)")
            options[option] = kind
            if let role { roles[option] = role }
        }
        let required = Set(fields["required"] as? [String] ?? [])
        for option in required where options[option] == nil {
            throw Problem(description: "instructions.\(name) requires --\(option), which it doesn't declare")
        }
        var count: ClosedRange<Int> = 0...0
        var argumentRoles: [InstructionSpec.Role] = []
        if let arguments = fields["arguments"] as? [String: Any] {
            count = try Self.count(arguments["count"], at: "instructions.\(name).arguments.count")
            argumentRoles = try (arguments["roles"] as? [String] ?? []).map { word throws(Problem) in
                try Self.role(word, at: "instructions.\(name).arguments.roles")
            }
        }
        return InstructionSpec(name, options: options, required: required, arguments: count, argumentRoles: argumentRoles,
                               optionRoles: roles, layer: (fields["layer"] as? String) == "suggested",
                               mayAsk: fields["may-ask"] as? Bool ?? false, readsData: fields["reads-data"] as? [String] ?? [])
    }

    /// `value`, `flag` or `repeated`, alone or as `{ kind: …, role: … }`.
    static func option(_ declared: Any, at path: String) throws(Problem) -> (InstructionSpec.OptionKind, InstructionSpec.Role?) {
        if let kind = declared as? String { return (try Self.kind(kind, at: path), nil) }
        guard let fields = declared as? [String: Any], let kind = fields["kind"] as? String else {
            throw Problem(description: "\(path) is a kind (value, flag, repeated) or { kind, role }")
        }
        return (try Self.kind(kind, at: path), try (fields["role"] as? String).map { word throws(Problem) in try Self.role(word, at: path) })
    }

    static func kind(_ word: String, at path: String) throws(Problem) -> InstructionSpec.OptionKind {
        switch word {
        case "value": .value
        case "flag": .flag
        case "repeated": .repeated
        default: throw Problem(description: "\(path): \(word) isn't value, flag or repeated")
        }
    }

    static func role(_ word: String, at path: String) throws(Problem) -> InstructionSpec.Role {
        switch word {
        case "location": .location
        case "program": .program
        case "input": .input
        case "copy-source": .copySource
        case "file": .file
        case "text": .text
        default: throw Problem(description: "\(path): \(word) isn't a role")
        }
    }

    /// `1`, `1...2`, or `1...` for any number from 1.
    static func count(_ value: Any?, at path: String) throws(Problem) -> ClosedRange<Int> {
        if let exact = value as? Int { return exact...exact }
        guard let text = value as? String else { return 0...0 }
        if let exact = Int(text) { return exact...exact }
        let parts = text.components(separatedBy: "...")
        guard parts.count == 2, let low = Int(parts[0]) else {
            throw Problem(description: "\(path): \(text) isn't <n>, <n>...<m> or <n>...")
        }
        if parts[1].isEmpty { return low...Int.max }
        guard let high = Int(parts[1]), high >= low else { throw Problem(description: "\(path): \(text) isn't a range") }
        return low...high
    }
}
