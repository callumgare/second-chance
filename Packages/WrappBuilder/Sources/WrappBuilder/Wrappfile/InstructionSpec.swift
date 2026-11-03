//
//  InstructionSpec.swift
//  WrappBuilder
//
//  What an instruction takes: the core's, and each module's.

import Foundation

/// What an instruction may be given: its options and how many arguments.
public nonisolated struct InstructionSpec: Sendable {
    public let name: String
    /// Every option it takes, by name, and whether it needs a value.
    public let options: [String: OptionKind]
    /// Options it can't do without.
    public let required: Set<String>
    public let arguments: ClosedRange<Int>
    /// For an instruction that names one of an edition's inputs as its first
    /// argument (`steam.INSTALL game`).
    public let firstArgumentIsInput: Bool

    public enum OptionKind: Sendable {
        /// `--name`
        case flag
        /// `--name=value`
        case value
        /// `--name=value`, given any number of times (`--mount`)
        case repeated
    }

    public init(_ name: String, options: [String: OptionKind] = [:], required: Set<String> = [],
                arguments: ClosedRange<Int> = 0...0, firstArgumentIsInput: Bool = false) {
        self.name = name
        self.options = options
        self.required = required
        self.arguments = arguments
        self.firstArgumentIsInput = firstArgumentIsInput
    }

    /// Options every step takes: its name, for conditions and reports.
    static let everyStep: [String: OptionKind] = ["name": .value]

    /// The core's instructions, which every stage has.
    public static let core: [String: InstructionSpec] = {
        let specs = [
            InstructionSpec("ARG", arguments: 1...1),
            InstructionSpec("USE", arguments: 1...3),
            InstructionSpec("RUN", options: ["mount": .repeated, "creates": .value, "with": .value, "on-failure": .value,
                                             "describe": .value, "if-skipped": .value, "ask": .value],
                            arguments: 1...Int.max),
            InstructionSpec("COPY", options: ["from": .value], arguments: 2...2),
            // `--unpack=zip --member=<file>` takes one file out of a zip; `--extract`
            // unpacks that file too (a self-extracting zip).
            InstructionSpec("ADD", options: ["checksum": .value, "unpack": .value, "member": .value, "extract": .flag],
                            required: ["checksum"], arguments: 2...2),
            InstructionSpec("EXPORT", arguments: 1...1),
            InstructionSpec("MOVE", arguments: 2...2),
            InstructionSpec("REMOVE", arguments: 1...1),
            // `--ini=<section>.<key>=<value>`, or `--from-data=<table>`: the calling
            // module's table of replacements and settings (nancy-drew's `ini`).
            InstructionSpec("EDIT", options: ["ini": .repeated, "from-data": .value], arguments: 1...1),
        ]
        return Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) })
    }()

    /// The mount types `RUN --mount=type=…` takes.
    public static let mountTypes: Set<String> = ["source", "cache", "secret", "bind", "fetch", "volume"]
}
