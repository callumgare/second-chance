//
//  StepContext.swift
//  WrappModuleKit
//
//  What a build gives an executor to carry a step out with.

import Foundation
import Logging

/// Everything an executor uses, and nothing else: the step's tree, the
/// plan's files, the inputs, the emitter and the person, running programs,
/// fetching downloads, and the log. The runner implements it directly; a
/// module's program gets one that forwards each call to the build. An
/// executor can't tell the two apart.
public nonisolated protocol StepContext: Sendable {
    /// The tree the step runs in: a folder laid out as a wrapp (`<stage>.app`),
    /// so `WrappLayout(app:)` works on it.
    var tree: URL { get }

    /// Another stage's tree, by name, to read from.
    func tree(ofStage name: String) -> URL?

    /// Where a place in full form is in the step's tree: a bare `/…` the
    /// core's, a typed one (`wine:C:/…`) wherever its type's module says;
    /// nil for one with no place in the app. How an executor finds a path a
    /// step names, rather than knowing any type's meaning itself.
    func location(of fullForm: String) -> URL?

    /// A file the plan reads, by its full form (`bundle:assets/disc.iss`,
    /// `module:nancy-drew:/assets/x.au3`), where it is on this Mac.
    func file(_ fullForm: String) -> URL?

    /// An input's folder or file, by name: resolved only when asked for, so
    /// disc 2 is asked for when a step needs it.
    func input(_ name: String) async throws -> URL

    /// The input, or nil when the build has none of that name (a one-disc
    /// game's disc 2).
    func inputIfGiven(_ name: String) async throws -> URL?

    /// A file of a module's own folder (its data tables, assets), by the
    /// module's id and the file's path in it: what an executor reads of its
    /// own module's, as its `reads-data` says.
    func moduleFile(_ module: String, _ path: String) -> URL?

    /// Where events go.
    var emitter: any EventEmitter { get }

    /// Ask the person something, and wait for the answer.
    func ask(_ question: StepQuestion) async throws -> StepAnswer

    /// Run a program as a `RUN` step would: by its path type, through the
    /// module that registered it, with its mounts in place; its exit code.
    func runProgram(_ program: ProgramRun, mounts: [String]) async throws -> Int32

    /// A download, by its URL and sha256, through the download cache.
    func fetch(url: URL, sha256: String) async throws -> URL

    /// The build's log, for this step.
    var log: Logger { get }

    /// The folder of a store the step is given (an option whose role is
    /// `store`, which the plan names in full: `steam:sign-in`), held under
    /// its lock until the step ends. A kept store only for its own module's
    /// executor.
    func store(_ name: String) async throws -> URL

    /// The program the step's signals are about (`${program.…}`), once
    /// it's chosen: the step's watches about it start then.
    func watch(program: WatchedProgram)

    /// A line the step's program wrote, for `WATCH --output`.
    func programWrote(_ line: String)

    /// The step's program ended with `code`, for `WATCH --exits`.
    func programExited(_ code: Int32)

    /// Call `handler` each time the signal the step's `option` names
    /// (`alive`, `done` or `asks`) fires, with its fields, while the step
    /// runs; nothing when it names none.
    func onSignal(_ option: String, _ handler: @escaping @Sendable ([String: String]) -> Void)

    /// Whether the step names a signal for `option`.
    func hasSignal(_ option: String) -> Bool
}

nonisolated extension StepContext {
    /// A string for the caller, which the builder never reads (`EMIT`).
    public func emit(_ string: String) { emitter.emit(.emitted(string)) }

    /// What the step is doing now, shown under it.
    public func substep(_ text: String) { emitter.emit(.substep(text)) }
}

/// A question a step asks the person, which the caller answers: through
/// its windows, or for a headless build, from what it was given up front.
public nonisolated enum StepQuestion: Sendable, Equatable, Codable {
    /// A step failed that may be carried on without (`--on-failure=ask`).
    case confirmStepFailure(name: String, message: String)
    /// One of several things, by text (a module someone added asks this).
    case choose(prompt: String, options: [String])
    /// Yes or no.
    case confirm(prompt: String)
}

public nonisolated enum StepAnswer: Sendable, Equatable, Codable {
    case yes, no
    case chose(Int)
}

/// Where a build's events go, in order. Emitting never waits.
public nonisolated protocol EventEmitter: Sendable {
    func emit(_ event: BuildEvent)
}

/// What a build tells its caller as it goes, the builder's own kinds: what
/// the caller shows or records it turns into its own events.
public nonisolated enum BuildEvent: Sendable, Equatable, Codable {
    /// A step began; its key is the step's place and text.
    case stepStarted(StepRef)
    /// A step's result was restored from a layer rather than run.
    case stepRestored(StepRef)
    /// A step finished.
    case stepDone(StepRef)
    /// A step failed, and the build carries on without it.
    case stepSkipped(StepRef, message: String)
    /// A string the Wrappfile or an executor emitted, which the builder
    /// passes on unread (`EMIT`).
    case emitted(String)
    /// What the person must do now; nil when that's over.
    case instructions(String?)
    /// How far the current step has got; nil clears it.
    case stepProgress(Progress?)
    /// What the current step is doing, in a few words.
    case substep(String)
    /// One of a module's own events, which its caller decodes by the
    /// module's package: the builder carries it without reading it.
    case module(id: String, name: String, payload: Data, lasting: Bool)
    /// An event a restored layer kept, emitted again as the layer is
    /// restored: what a fresh build would have shown.
    indirect case replayed(BuildEvent)
    /// A store's lock is someone else's (`holder`, as its file names
    /// them), so the build waits for it.
    case lockWaiting(lock: String, holder: String?)
    /// The build has the lock, after waiting `seconds` for it.
    case lockAcquired(lock: String, seconds: Double)

    public struct Progress: Sendable, Equatable, Codable {
        public var fraction: Double?
        public var text: String?

        public init(fraction: Double?, text: String?) {
            self.fraction = fraction
            self.text = text
        }
    }

    /// Whether it's a fact about the build, kept with a layer and replayed
    /// when the layer is restored, or true only as it happens.
    public var lasting: Bool {
        switch self {
        case .stepStarted, .stepRestored, .stepDone, .stepSkipped, .emitted: true
        case .instructions, .stepProgress, .substep, .lockWaiting, .lockAcquired: false
        case .module(_, _, _, let lasting): lasting
        case .replayed: false
        }
    }
}

/// A step as events name it: its place and what it says.
public nonisolated struct StepRef: Sendable, Equatable, Codable {
    /// The stage it's in.
    public let stage: String
    /// Its place in the stage, from 0.
    public let index: Int
    public let step: PlannedStep

    public init(stage: String, index: Int, step: PlannedStep) {
        self.stage = stage
        self.index = index
        self.step = step
    }

    /// Its `--name`, or where it was written.
    public var name: String { step.name ?? step.origin }
}
