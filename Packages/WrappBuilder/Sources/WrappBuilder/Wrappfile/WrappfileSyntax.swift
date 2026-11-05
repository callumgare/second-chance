//
//  WrappfileSyntax.swift
//  WrappBuilder
//
//  A Wrappfile, parsed: its global declarations, functions and stages.

import Foundation

/// A parsed Wrappfile (docs/wrappfile.md): Dockerfile-like build steps,
/// in stages, with functions of shared steps. Parsing only reads the text;
/// `WrappfileChecker` says whether it makes sense for its bundle.
public nonisolated struct Wrappfile: Sendable, Equatable {
    /// `INPUT`, `CONST` and `VAR` before the first `FROM`, in order.
    public var globals: [Instruction] = []
    /// `STORE` and `LOCK` before the first `FROM`, in order.
    public var storeDeclarations: [Instruction] = []
    public var functions: [WrappfileFunction] = []
    /// `SIGNAL` blocks, outside every stage and function.
    public var signals: [WrappfileSignal] = []
    public var stages: [Stage] = []

    /// Stage and function names are case-insensitive, as Docker's stage names are.
    public func stage(named name: String) -> Stage? { stages.first { $0.name == name.lowercased() } }
    public func function(named name: String) -> WrappfileFunction? { functions.first { $0.name == name.lowercased() } }
}

/// `INPUT`, `CONST`, `VAR` or `SET`: a name, and the value it's given.
public nonisolated struct Declaration: Sendable, Equatable {
    public let kind: Kind
    public let name: String
    public let value: Word?
    public let line: Int

    public enum Kind: String, Sendable {
        case input = "INPUT", const = "CONST", variable = "VAR", set = "SET"
    }

    /// The declaration an instruction makes, if it's one.
    public init?(_ instruction: Instruction) {
        guard let kind = Kind(rawValue: instruction.keyword), let name = instruction.arguments.first?.raw else { return nil }
        self.kind = kind
        self.name = name
        self.value = kind == .input ? instruction.option("default")?.value : instruction.arguments.dropFirst().first
        self.line = instruction.line
    }
}

/// `SIGNAL <name> [--all|--any]` … `END`: what to watch for, as `WATCH`
/// lines (docs/wrappfile.md#signals).
public nonisolated struct WrappfileSignal: Sendable, Equatable {
    public enum Combine: String, Sendable, Codable { case all, any }
    /// In lower case.
    public let name: String
    public let combine: Combine
    public let watches: [Instruction]
    public let line: Int
}

public nonisolated struct WrappfileFunction: Sendable, Equatable {
    /// In lower case.
    public let name: String
    public let body: [Step]
    public let line: Int
    /// As written, for the warning about upper case.
    public var nameAsWritten: String?

    /// Its parameters: the `INPUT`s at its top, with their defaults.
    public var parameters: [Declaration] {
        body.compactMap { step in
            guard case .instruction(let instruction) = step, let declaration = Declaration(instruction),
                  declaration.kind == .input else { return nil }
            return declaration
        }
    }
}

public nonisolated struct Stage: Sendable, Equatable {
    /// From `AS <name>`, in lower case; nil for a stage nothing names.
    public let name: String?
    public let from: StageSource
    public let body: [Step]
    public let line: Int
    /// As written, for the warning about upper case.
    public var nameAsWritten: String?
}

/// What a stage starts from.
public nonisolated enum StageSource: Sendable, Equatable, CustomStringConvertible {
    /// As a Wrappfile writes it.
    public var description: String {
        switch self {
        case .scratch: "scratch"
        case .stage(let name): name
        case .module(let id, let constraint, let stage): "--module=\(id)\(constraint.map { "@\($0)" } ?? "") \(stage)"
        }
    }

    /// The bare wrapp template.
    case scratch
    /// A stage of this Wrappfile, or the old wrapp an update is built from
    /// (`previous`).
    case stage(String)
    /// A module's stage: `FROM --module=steam@2 client`.
    case module(id: String, constraint: String?, stage: String)
}

public nonisolated indirect enum Step: Sendable, Equatable {
    case instruction(Instruction)
    /// `IF` … `ELSE IF` … `ELSE` … `END`: each branch's condition (nil for
    /// `ELSE`) and steps; the first that holds runs.
    case conditional([Branch])
    /// `LAYER-HINT` … `END`.
    case layer([Step], line: Int)

    public struct Branch: Sendable, Equatable {
        public let condition: Condition?
        public let steps: [Step]
        public let line: Int
    }

    /// Every instruction in it, branches and layers included, in order.
    public var instructions: [Instruction] {
        switch self {
        case .instruction(let instruction): [instruction]
        case .conditional(let branches): branches.flatMap { $0.steps.flatMap(\.instructions) }
        case .layer(let steps, _): steps.flatMap(\.instructions)
        }
    }
}

/// One instruction: its keyword (`RUN`, `COPY`, `WINE.MOUNT`, `DO`), its
/// `--options`, and its arguments.
public nonisolated struct Instruction: Sendable, Equatable {
    /// In upper case, however it was written.
    public let keyword: String
    public let options: [InstructionOption]
    public let arguments: [Word]
    public let line: Int

    /// The module alias of a module's instruction, in lower case as a
    /// module's name is (`wine` for `WINE.MOUNT`); nil for a core one.
    /// `MODULE.<NAME>.<INSTRUCTION>` names the module in full, for one
    /// whose name is the core's.
    public var moduleAlias: String? {
        let parts = keyword.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 3, parts[0] == "MODULE" { return parts[1].lowercased() }
        guard parts.count == 2 else { return nil }
        return parts[0].lowercased()
    }

    /// Its name without the alias (`MOUNT`).
    public var name: String {
        guard let dot = keyword.lastIndex(of: ".") else { return keyword }
        return String(keyword[keyword.index(after: dot)...])
    }

    public func option(_ name: String) -> InstructionOption? { options.first { $0.name == name } }
    public func options(_ name: String) -> [InstructionOption] { options.filter { $0.name == name } }
}

/// `--name` or `--name=value`.
public nonisolated struct InstructionOption: Sendable, Equatable {
    public let name: String
    public let value: Word?

    /// A `--mount=…` value's `key=value` fields.
    public var fields: [String: String] {
        guard let raw = value?.raw else { return [:] }
        var fields: [String: String] = [:]
        for part in raw.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1)
            fields[String(pair[0])] = pair.count > 1 ? String(pair[1]) : ""
        }
        return fields
    }
}

/// An argument or option value, with the `${…}` substitutions in it.
public nonisolated struct Word: Sendable, Equatable, CustomStringConvertible {
    /// As written, quotes removed.
    public let raw: String
    public let parts: [Part]
    /// Whether it was written in quotes, which keeps a lone `${…}` text.
    public var quoted = false

    public enum Part: Sendable, Equatable {
        case text(String)
        /// What's between `${` and `}`: `input.disc-1`, `const.install-dir`,
        /// `self.data.patches[input.id].url`.
        case substitution(String)
    }

    public var description: String { raw }

    /// Every substitution in it.
    public var substitutions: [String] {
        parts.compactMap { part in
            if case .substitution(let inner) = part { inner } else { nil }
        }
    }

    /// The reference it is, when it's one `${…}` and nothing else.
    public var lone: Reference? {
        guard parts.count == 1, case .substitution(let inner) = parts[0] else { return nil }
        return try? Reference.parse(inner)
    }
}

/// An `IF` condition: two expressions, each a `${…}` or a quoted string,
/// compared (`${input.launch-mode} = "direct"`).
public nonisolated struct Condition: Sendable, Equatable {
    public let left: Word
    public let comparison: Comparison
    public let right: Word

    public enum Comparison: String, Sendable {
        case equals = "=", notEquals = "!="
    }
}

/// A parse error, with the line it's on.
public nonisolated struct WrappfileError: Error, Equatable, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}
