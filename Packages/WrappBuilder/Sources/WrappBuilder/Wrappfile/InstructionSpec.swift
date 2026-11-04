//
//  InstructionSpec.swift
//  WrappBuilder
//
//  What an instruction takes: the core's, and each module's.

import Foundation

/// What an instruction may be given: its options and how many arguments,
/// and what each is (a place in the app, a program, an input…), which the
/// checker and planner read to know which words are paths.
public nonisolated struct InstructionSpec: Sendable, Equatable {
    /// In upper case: `RUN`, or `KEEP-DISCS` for `WINE.KEEP-DISCS`.
    public let name: String
    /// Every option it takes, by name, and whether it needs a value.
    public let options: [String: OptionKind]
    /// Options it can't do without.
    public let required: Set<String>
    public let arguments: ClosedRange<Int>
    /// What each argument is, in order; the last goes for every argument
    /// after it. Plain text when there are none.
    public let argumentRoles: [Role]
    /// What each option's value is; plain text for one not named.
    public let optionRoles: [String: Role]
    /// Whether its module says a layer after it is worth keeping
    /// (`layer: suggested`).
    public let layer: Bool
    /// Whether it may ask the person something (`may-ask: true`), so no
    /// lock is held while it runs.
    public let mayAsk: Bool
    /// Its module's data tables its Swift reads (`reads-data: [ini]`),
    /// which are part of its key.
    public let readsData: [String]

    public enum OptionKind: Sendable, Equatable {
        /// `--name`
        case flag
        /// `--name=value`
        case value
        /// `--name=value`, given any number of times (`--mount`)
        case repeated
    }

    /// What a word is, which says how it's checked and planned.
    public enum Role: Sendable, Equatable {
        /// A place in the app: a path in a location type, a short form one
        /// claims, or a bare `/…` path in the app's `Contents/`.
        case location
        /// A program, in a program type or a short form one claims.
        case program
        /// One of the edition's inputs (`STEAM.INSTALL game`).
        case input
        /// A path in what `COPY --from` copies from: a stage, or an input.
        case copySource
        /// A file the build reads: the bundle's, written as a relative path,
        /// or a module's (`module:<id>:/<path>`).
        case file
        /// Text, used as it is: a program's own arguments, a URL.
        case text
    }

    public init(_ name: String, options: [String: OptionKind] = [:], required: Set<String> = [],
                arguments: ClosedRange<Int> = 0...0, argumentRoles: [Role] = [], optionRoles: [String: Role] = [:],
                layer: Bool = false, mayAsk: Bool = false, readsData: [String] = []) {
        self.name = name
        self.layer = layer
        self.mayAsk = mayAsk
        self.readsData = readsData
        self.options = options
        self.required = required
        self.arguments = arguments
        self.argumentRoles = argumentRoles
        self.optionRoles = optionRoles
    }

    /// What argument `index` is.
    public func role(ofArgument index: Int) -> Role {
        guard !argumentRoles.isEmpty else { return .text }
        return argumentRoles[min(index, argumentRoles.count - 1)]
    }

    /// What `--<name>`'s value is.
    public func role(ofOption name: String) -> Role { optionRoles[name] ?? .text }

    /// For an instruction that names one of an edition's inputs as its first
    /// argument (`STEAM.INSTALL game`).
    public var firstArgumentIsInput: Bool { argumentRoles.first == .input }

    /// Options every step takes: its name, for reports; and what a failure
    /// does, `--on-failure=ask` asking whether to carry on without it, where
    /// otherwise a failed step fails the build.
    static let everyStep: [String: OptionKind] = ["name": .value, "on-failure": .value, "progress": .value]

    /// The core's instructions, which every stage has.
    public static let core: [String: InstructionSpec] = {
        let specs = [
            InstructionSpec("USE", arguments: 1...3),
            // `--env NAME=<value>`, as many as needed: the only way a value
            // reaches a program's environment.
            InstructionSpec("RUN", options: ["mount": .repeated, "env": .repeated],
                            arguments: 1...Int.max, argumentRoles: [.program, .text]),
            InstructionSpec("COPY", options: ["from": .value], arguments: 2...2, argumentRoles: [.copySource, .location]),
            // `--unpack=zip --member=<file>` takes one file out of a zip; `--extract`
            // unpacks that file too (a self-extracting zip).
            InstructionSpec("ADD", options: ["checksum": .value, "unpack": .value, "member": .value, "extract": .flag],
                            required: ["checksum"], arguments: 2...2, argumentRoles: [.text, .location]),
            // How the wrapp starts its program: recorded with the plan, not a step.
            InstructionSpec("LAUNCH", options: ["fallback": .value, "env": .repeated], arguments: 1...Int.max,
                            argumentRoles: [.program, .text], optionRoles: ["fallback": .program]),
            // A volume of the manifest's, where the program sees it; or with
            // --remove, one taken off. Recorded with the launch.
            InstructionSpec("VOLUME", options: ["remove": .flag], arguments: 1...2, argumentRoles: [.text, .location]),
            // What the app is: its id when the caller gives none, its name, and
            // its icon, an .icns in its Resources/. Recorded with the plan.
            InstructionSpec("APP", options: ["default-id": .value, "name": .value, "icon": .value],
                            optionRoles: ["icon": .location]),
            InstructionSpec("MOVE", arguments: 2...2, argumentRoles: [.location]),
            // A string for whoever runs the build, passed on unread as it gets
            // here: not a step, so in no key and keeping no layer.
            InstructionSpec("EMIT", arguments: 1...1, argumentRoles: [.text]),
            InstructionSpec("REMOVE", arguments: 1...1, argumentRoles: [.location]),
            // `--ini=<section>.<key>=<value>`, as many as needed.
            // `--keys-must-exist`: each setting must already be in the file, or
            // the step fails, naming those that aren't; without it one is added.
            InstructionSpec("EDIT", options: ["ini": .repeated, "plist": .repeated, "keys-must-exist": .flag, "create": .flag], arguments: 1...1,
                            argumentRoles: [.location]),
        ]
        return Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) })
    }()

    /// The mount types `RUN --mount=type=…` takes.
    public static let mountTypes: Set<String> = ["cache", "secret", "bind", "fetch"]

    /// What each core mount field is; plain text for the rest.
    public static let mountFieldRoles: [String: Role] = ["target": .location, "source": .file]

    /// The keywords that declare or assign a value, which have rules of
    /// their own.
    public static let declarations: Set<String> = ["INPUT", "CONST", "VAR", "SET"]

    /// What's recorded with the plan rather than run as a step: the launch,
    /// its volumes, and what the app is.
    public static let recorded: Set<String> = ["LAUNCH", "VOLUME", "APP"]

    /// The words that start or end a block, or a stage: compared in upper
    /// case, as every keyword is.
    static let blockWords: Set<String> = ["IF", "ELSE", "END", "FROM", "AS", "FUNCTION", "LAYER-HINT"]
}
