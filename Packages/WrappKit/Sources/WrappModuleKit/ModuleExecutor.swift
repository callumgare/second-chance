//
//  ModuleExecutor.swift
//  WrappModuleKit
//
//  What a module's Swift is to a build: its executor.

import Foundation

/// A module's part in carrying out a plan: its instructions, and its
/// additions to the core's (`RUN`'s programs of its path type). Made once
/// per build; it may hold what lasts between steps (a running Steam) in its
/// session, but a step's only results are its tree and its events, so a
/// later step never reads anything it kept.
///
/// The same API serves an executor compiled into Second Chance and one in a
/// module's own program, so a module someone wrote can become a shipped one
/// with its code unchanged.
public nonisolated protocol ModuleExecutor: Sendable {
    /// The instructions it carries out, which its module's `build:` must
    /// declare, and only those.
    static var handles: [String] { get }

    /// The revision of what its Swift makes, raised whenever a change to it
    /// changes what a step makes: part of every one of its steps' keys, so
    /// layers its earlier Swift made aren't restored.
    static var revision: Int { get }

    /// What a step's key needs beyond its text: a disc's listing, an
    /// installer's fingerprint.
    func keyInputs(for step: PlannedStep, in context: any StepContext) async throws -> KeyInputs

    /// Carry `step` out in `context.tree`.
    func run(_ step: PlannedStep, in context: any StepContext) async throws

    /// Run a program of this module's path type (`RUN wine:C:/…`), as `RUN`
    /// and `context.runProgram` do, returning its exit code.
    func runProgram(_ program: ProgramRun, in context: any StepContext) async throws -> Int32

    /// One of its module's watches (`WATCH --wine.busy`), for a step in
    /// `context`: nil for one it doesn't have.
    func watch(_ name: String, value: String?, in context: any StepContext) -> (any WatchProbe)?

    /// Make the tree safe to keep as a layer: nothing running in it, and
    /// everything it holds written to disk.
    func checkpoint(_ context: any StepContext) async throws

    /// End whatever the build started, on success, failure or cancel.
    func finish() async
}

nonisolated extension ModuleExecutor {
    public static var revision: Int { 1 }

    public func keyInputs(for step: PlannedStep, in context: any StepContext) async throws -> KeyInputs { KeyInputs() }

    public func runProgram(_ program: ProgramRun, in context: any StepContext) async throws -> Int32 {
        throw StepFailure.recipe("\(program.step.origin): this module runs no programs (\(program.program))")
    }

    public func watch(_ name: String, value: String?, in context: any StepContext) -> (any WatchProbe)? { nil }

    public func checkpoint(_ context: any StepContext) async throws {}

    public func finish() async {}
}

/// A program to run as a `RUN` step would: by its path type, through the
/// module that registered it, with its mounts put in place first.
public nonisolated struct ProgramRun: Sendable, Codable {
    /// In full form: `wine:C:/setup.exe`.
    public var program: String
    public var arguments: [String]
    /// `--env NAME=<value>`, by name.
    public var environment: [String: String]
    /// The longest it may take; nil for the build's own limit.
    public var timeout: Duration?
    /// The step it's for, for its origin and log.
    public var step: PlannedStep

    public init(program: String, arguments: [String] = [], environment: [String: String] = [:],
                timeout: Duration? = nil, step: PlannedStep) {
        self.program = program
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.step = step
    }
}

/// The facts from outside the plan that a step's key is made of, each named,
/// in order.
public nonisolated struct KeyInputs: Sendable, Equatable, Codable {
    public var inputs: [KeyInput]

    public init(_ inputs: [KeyInput] = []) { self.inputs = inputs }
}

public nonisolated struct KeyInput: Sendable, Equatable, Codable {
    public let name: String
    public let value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// Why a step failed, which the build turns into what the person sees.
public nonisolated enum StepFailure: Error, Sendable, Equatable, CustomStringConvertible, Codable {
    /// What the Wrappfile or a module says can't be done: a recipe problem.
    case recipe(String)
    /// The step was tried and failed.
    case failed(String)

    public var description: String {
        switch self {
        case .recipe(let message), .failed(let message): message
        }
    }
}
