//
//  WrappfileSyntax.swift
//  WrappBuilder
//
//  A Wrappfile, parsed: its global ARGs, functions and stages.

import Foundation

/// A parsed Wrappfile (docs/wrappfile.md): Dockerfile-like build steps,
/// in stages, with functions of shared steps. Parsing only reads the text;
/// `WrappfileChecker` says whether it makes sense for its bundle.
public nonisolated struct Wrappfile: Sendable, Equatable {
    /// `ARG <name>=<value>` before the first `FROM`.
    public var globalArgs: [ArgDeclaration] = []
    public var functions: [WrappfileFunction] = []
    public var stages: [Stage] = []

    public func stage(named name: String) -> Stage? { stages.first { $0.name == name } }
    public func function(named name: String) -> WrappfileFunction? { functions.first { $0.name == name } }
}

public nonisolated struct ArgDeclaration: Sendable, Equatable {
    public let name: String
    public let value: Word?
    public let line: Int
}

public nonisolated struct WrappfileFunction: Sendable, Equatable {
    public let name: String
    public let body: [Step]
    public let line: Int

    /// Its parameters: the `ARG`s its body declares, with their defaults.
    public var parameters: [ArgDeclaration] {
        body.compactMap { step in
            guard case .instruction(let instruction) = step, instruction.keyword == "ARG",
                  let word = instruction.arguments.first else { return nil }
            return WrappfileParser.argDeclaration(word, line: instruction.line)
        }
    }
}

public nonisolated struct Stage: Sendable, Equatable {
    /// From `AS <name>`; nil for a stage nothing names.
    public let name: String?
    public let from: StageSource
    public let body: [Step]
    public let line: Int
}

/// What a stage starts from.
public nonisolated enum StageSource: Sendable, Equatable {
    /// The bare wrapp template.
    case scratch
    /// A stage of this Wrappfile, or one Second Chance supplies (`base`,
    /// `previous`).
    case stage(String)
    /// A module's stage: `FROM steam@2/client`.
    case module(id: String, constraint: String?, stage: String)
}

public nonisolated indirect enum Step: Sendable, Equatable {
    case instruction(Instruction)
    /// `IF` … `ELSE IF` … `ELSE` … `END`: each branch's condition (nil for
    /// `ELSE`) and steps; the first that holds runs.
    case conditional([Branch])
    /// `LAYER` … `END`.
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

/// One instruction: its keyword (`RUN`, `COPY`, `wine.MOUNT`, `DO`), its
/// `--options`, and its arguments.
public nonisolated struct Instruction: Sendable, Equatable {
    public let keyword: String
    public let options: [InstructionOption]
    public let arguments: [Word]
    public let line: Int

    /// The module alias of a module's instruction (`wine` for
    /// `wine.MOUNT`); nil for a core one.
    public var moduleAlias: String? {
        guard let dot = keyword.firstIndex(of: ".") else { return nil }
        return String(keyword[..<dot])
    }

    /// Its name without the alias (`MOUNT`).
    public var name: String {
        guard let dot = keyword.firstIndex(of: ".") else { return keyword }
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

    public enum Part: Sendable, Equatable {
        case text(String)
        /// What's between `${` and `}`: `install-dir`, `inputs.game.app-id`,
        /// `assets/disc.iss`, `data.patches.${id}.url`.
        case substitution(String)
    }

    public var description: String { raw }

    /// Every substitution in it, those nested in another's included.
    public var substitutions: [String] {
        parts.flatMap { part -> [String] in
            guard case .substitution(let inner) = part else { return [] }
            let nested = (try? WrappfileParser.parts(of: inner, line: 0)) ?? []
            return [inner] + nested.compactMap { if case .substitution(let s) = $0 { s } else { nil } }
        }
    }
}

/// An `IF` condition: `arch=arm64`, `macos>=26`, `launch-mode!=steam`,
/// `updates has taffy-patch`, or a bare name that holds when it's set
/// (`updates`).
public nonisolated struct Condition: Sendable, Equatable {
    public let name: String
    public let comparison: Comparison?
    public let value: String?

    public enum Comparison: String, Sendable {
        case equals = "=", notEquals = "!=", atLeast = ">=", atMost = "<=", greater = ">", less = "<", has = "has"
    }
}

/// A parse error, with the line it's on.
public nonisolated struct WrappfileError: Error, Equatable, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}
