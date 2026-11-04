//
//  BuildPlan.swift
//  WrappBuilder
//
//  An edition's build, worked out from its Wrappfile before anything runs.

import CryptoKit
import Foundation
import WrappModules
import WrappFormat
// A plan's steps are the executors' API's: whoever plans one can run it.
@_exported import WrappModuleKit

/// What a build of one edition runs, in order: the stages its target needs,
/// each with its steps, functions expanded, `${…}` substituted and `IF`s
/// decided for this build. Worked out before anything runs (`BuildPlanner`), so a
/// mistake shows before a disc is copied, and the plan can be logged,
/// compared and keyed.
public nonisolated struct BuildPlan: Sendable, Equatable {
    public let edition: String
    /// Dependencies first; the last is the target.
    public let stages: [PlannedStage]
    /// The bundle's and modules' files its steps read, by their full form
    /// (`bundle:assets/disc.iss`, `module:nancy-drew:/assets/x.au3`), with
    /// where each is: what install layers hash and builders read.
    public var files: [String: URL] = [:]
    /// How the wrapp starts its program: the target's `LAUNCH`, with the
    /// `VOLUME`s it has. Nil only for an update's plan built `FROM previous`,
    /// which keeps the old wrapp's.
    public var launch: RecordedLaunch?
    /// What `APP` says the app is, the target's: its icon
    /// (`/Resources/<name>.icns`, nil for the template's own), its name, and
    /// the id to give it when the caller gives none.
    public var app = RecordedApp()
    public var icon: String? { app.icon }

    public init(edition: String, stages: [PlannedStage]) {
        self.edition = edition
        self.stages = stages
    }

    public var target: PlannedStage? { stages.last }

    /// The steps of the bundle's own stages: what a builder runs, a module's
    /// stage (`wine/prefix`, the prefix Wine's build makes) being the
    /// module's to make.
    public var bundleSteps: [PlannedStep] { stages.filter { !$0.isModuleStage }.flatMap(\.steps) }

    /// The file a step names in full form, if the plan read one.
    public func file(_ fullForm: String) -> URL? { files[fullForm] }
}

public nonisolated struct PlannedStage: Sendable, Equatable {
    public let name: String
    public let from: StageSource
    /// The modules it has, by id, its dependencies' and `FROM`'s included.
    public let modules: [String]
    public let steps: [PlannedStep]
    /// The module whose stage it is, by id; nil for the bundle's own.
    public let module: String?
    /// Its `EMIT`s, each with the step it comes before: not steps, so in no
    /// key, and passed to the caller unread as the build reaches them.
    public let emits: [PlannedEmit]

    public init(name: String, from: StageSource, modules: [String], steps: [PlannedStep], module: String? = nil,
                emits: [PlannedEmit] = []) {
        self.name = name
        self.from = from
        self.modules = modules
        self.steps = steps
        self.module = module
        self.emits = emits
    }

    /// The `EMIT`s expanded among `steps` taken out, each kept with the
    /// index of the step it came before.
    static func separatingEmits(_ steps: [PlannedStep]) -> (steps: [PlannedStep], emits: [PlannedEmit]) {
        var run: [PlannedStep] = []
        var emits: [PlannedEmit] = []
        for step in steps {
            if step.module == nil, step.instruction == "EMIT" {
                emits.append(PlannedEmit(before: run.count, text: step.arguments.first ?? "", origin: step.origin))
            } else {
                run.append(step)
            }
        }
        return (run, emits)
    }

    /// The strings emitted before step `index` (`steps.count` for after the last).
    public func emits(before index: Int) -> [PlannedEmit] { emits.filter { $0.before == index } }

    /// A module's stage (`wine/prefix`, named `<module>/<stage>`).
    public var isModuleStage: Bool { module != nil }

    /// What its steps say, one a line, as planned: what a wrapp's lock
    /// records of a module's stage, so its `when-changed` update runs when
    /// what the stage does changes, never for a comment or a reformat.
    public var plannedText: String { steps.map(\.description).joined(separator: "\n") }

    /// `plannedText`'s sha256.
    public var plannedTextHash: String {
        SHA256.hash(data: Data(plannedText.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// An `EMIT`: its string, where it was written, and the step it comes before.
public nonisolated struct PlannedEmit: Sendable, Equatable {
    public let before: Int
    public let text: String
    public let origin: String
}

/// What `APP` records: `--icon`, `--name` and `--default-id`, the last of
/// each a stage reaches winning, inherited through `FROM`.
public nonisolated struct RecordedApp: Sendable, Equatable {
    public var icon: String?
    public var name: String?
    public var defaultID: String?

    public init(icon: String? = nil, name: String? = nil, defaultID: String? = nil) {
        self.icon = icon
        self.name = name
        self.defaultID = defaultID
    }

    /// The app's id: the caller's, which wins, else the Wrappfile's
    /// default, else none, which is an error (decision 25 of the builders
    /// plan): an app is never named by accident.
    public func id(given: String?) throws(BuildPlanner.PlanError) -> String {
        if let given, !given.isEmpty { return given }
        if let defaultID { return defaultID }
        throw BuildPlanner.PlanError(description: "the app needs an id: give one, or the Wrappfile's APP --default-id")
    }
}

/// What a build knows before it starts, which `IF`s and `${…}` read.
public nonisolated struct BuildConditions: Sendable {
    /// `${platform.arch}`: `arm64` or `x86_64`, the Mac building the wrapp.
    public var arch: String
    /// `${platform.macos}`: its major version.
    public var macos: Int
    /// Values given to the edition's inputs (a choice's answer), by name,
    /// over their defaults.
    public var choices: [String: String]
    /// The updates this build applies (empty on a fresh build).
    public var updates: [String]
    /// What the old wrapp recorded (`previous.bundle`, `previous.wine`).
    public var previous: [String: String]

    public init(arch: String, macos: Int, choices: [String: String] = [:], updates: [String] = [], previous: [String: String] = [:]) {
        self.arch = arch
        self.macos = macos
        self.choices = choices
        self.updates = updates
        self.previous = previous
    }

    /// The Mac this runs on.
    public static var thisMac: BuildConditions {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return BuildConditions(arch: arch, macos: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}

/// Works out a `BuildPlan` from a checked bundle and the modules.
public nonisolated struct BuildPlanner {
    let bundle: ProgramBundle
    let wrappfile: Wrappfile
    let modules: [String: ModuleFolder]
    let pathTypes: PathTypeRegistry
    /// What each module declares: its `module.yaml`'s `build:`, unless a
    /// test gives its own.
    let declarations: @Sendable (ModuleFolder) -> ModuleDeclarations
    /// Where on the Mac the build may read the bundle's files from: the
    /// caller's grant (decision 24 of the builders plan).
    let hostPaths: HostPaths

    public struct PlanError: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// `pathTypes` are the shipped modules' unless a test gives its own.
    public init(bundle: ProgramBundle, wrappfile: Wrappfile, modules: [ModuleFolder],
                pathTypes: PathTypeRegistry = .shipped,
                declarations: @escaping @Sendable (ModuleFolder) -> ModuleDeclarations = { $0.declarations },
                hostPaths: HostPaths? = nil) {
        self.hostPaths = hostPaths ?? HostPaths(allowed: bundle.manifest.allowPaths ?? [])
        self.bundle = bundle
        self.wrappfile = wrappfile
        self.modules = Dictionary(modules.map { ($0.manifest.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        self.pathTypes = pathTypes
        self.declarations = declarations
    }

    /// The problems planning finds in any edition's target, for either kind
    /// of Mac and every value of every choice: what only a plan shows (a
    /// function's path in a stage without its module, an input given but
    /// never used) found when a bundle is checked, not when it's built.
    public func problemsPlanningEveryTarget() -> [String] {
        var problems: [String] = []
        for edition in bundle.manifest.editions where edition.build?.target != nil {
            var combinations: [[String: String]] = [[:]]
            for (name, choice) in (edition.choices ?? [:]).sorted(by: { $0.key < $1.key }) {
                combinations = combinations.flatMap { combination in choice.options.map { combination.merging([name: $0]) { $1 } } }
            }
            for arch in ["arm64", "x86_64"] {
                for combination in combinations {
                    do {
                        _ = try plan(edition: edition.id, conditions: BuildConditions(arch: arch, macos: 15, choices: combination))
                    } catch {
                        let chosen = combination.sorted { $0.key < $1.key }.map { ", \($0.key)=\($0.value)" }.joined()
                        problems.append("edition \(edition.id) (\(arch)\(chosen)) doesn't plan: \(error.description)")
                    }
                }
            }
        }
        return Array(Set(problems)).sorted()
    }

    /// The plan for `editionID`, built for `conditions`. Nil for an edition
    /// with no target: its builder builds it, as it did before Wrappfiles.
    /// An input the edition gives that the target never reads is an error,
    /// as it's a typo or something asked for no reason.
    public func plan(edition editionID: String, conditions: BuildConditions) throws(PlanError) -> BuildPlan? {
        guard let edition = bundle.manifest.editions.first(where: { $0.id == editionID }) else {
            throw PlanError(description: "\(bundle.manifest.id) has no edition called \(editionID)")
        }
        guard let target = edition.build?.target else { return nil }
        let recorder = Recorder()
        let plan = try plan(edition: edition, target: target, conditions: conditions, recorder: recorder)
        // cnc-ddraw is for a game that draws with DirectDraw, and such a game
        // needs it: the two are written together.
        if let launch = plan.launch, launch.options["wine.graphics"] != nil {
            let cncDdraw = plan.stages.flatMap(\.steps).contains {
                $0.module == ModuleID.wine.rawValue && $0.instruction == "WINETRICKS" && $0.arguments == ["cnc_ddraw"]
            }
            if cncDdraw != (launch.options["wine.graphics"] == "direct-draw") {
                throw PlanError(description: cncDdraw
                    ? "\(target) sets cnc-ddraw up, but its launch doesn't draw with DirectDraw (--wine.graphics=direct-draw)"
                    : "\(target)'s launch draws with DirectDraw, but nothing sets cnc-ddraw up (DO wine.cnc-ddraw)")
            }
            // cnc-ddraw swallows a game's first click unless the cursor is
            // locked, which only the launch asks for.
            if cncDdraw, launch.options["wine.cursor-lock"] == nil {
                throw PlanError(description: "\(target) sets cnc-ddraw up, so its launch needs --wine.cursor-lock, or the game's first click is swallowed")
            }
        }
        let unused = (edition.build?.inputs ?? []).map(\.id).filter { !recorder.usedInputs.contains($0) }
        if !unused.isEmpty {
            throw PlanError(description: "manifest.yaml's edition \(editionID) gives \(unused.joined(separator: ", ")), "
                + "which \(target) never reads")
        }
        return plan
    }

    /// The plan that builds the stage `target` for `editionID`: the
    /// edition's own target, or an update's (`updates[].build.target`).
    public func plan(edition editionID: String, target: String, conditions: BuildConditions) throws(PlanError) -> BuildPlan {
        guard let edition = bundle.manifest.editions.first(where: { $0.id == editionID }) else {
            throw PlanError(description: "\(bundle.manifest.id) has no edition called \(editionID)")
        }
        return try plan(edition: edition, target: target, conditions: conditions, recorder: Recorder())
    }

    func plan(edition: Manifest.Edition, target: String, conditions: BuildConditions,
              recorder: Recorder) throws(PlanError) -> BuildPlan {
        let context = Context(planner: self, edition: edition, conditions: conditions, recorder: recorder)
        var order: [String] = []
        try context.collect(target.lowercased(), into: &order)
        let globals = try context.globalScope()
        var stages: [PlannedStage] = []
        var modulesByStage: [String: StageModules] = [:]
        for name in order {
            guard let stage = wrappfile.stage(named: name) else {
                throw PlanError(description: "the Wrappfile has no stage called \(name)")
            }
            // A module's stage that is a Wrappfile (`FROM wine@10/prefix`) is
            // planned first, once, as a stage of its own (`wine/prefix`),
            // after the module stage it's built from, if any.
            try context.planModuleStages(stage.from, into: &stages, known: &modulesByStage)
            let planned = try context.plan(stage, globals: globals, inheriting: modulesByStage)
            modulesByStage[name] = planned.modules
            stages.append(planned.stage)
        }
        var plan = BuildPlan(edition: edition.id, stages: stages)
        plan.files = recorder.files
        let recorded = modulesByStage[target.lowercased()] ?? StageModules()
        if var launch = recorded.launch {
            launch.volumes = recorded.volumes
            plan.launch = launch
            // What an install expects to make is what the launch runs, when
            // the launch is in the folder it installs into, so the two can't
            // drift.
            for step in stages.flatMap(\.steps) {
                guard let creates = step.option("creates"), let into = step.option("into"),
                      launch.program.hasPrefix(into + "/"), creates != launch.program else { continue }
                throw PlanError(description: "\(step.origin): --creates=\(creates), but \(target) launches \(launch.program)")
            }
        } else if !recorded.fromPrevious {
            throw PlanError(description: "manifest.yaml's edition \(edition.id) builds \(target), which reaches no LAUNCH")
        }
        plan.app = recorded.app
        return plan
    }

    /// A module's stage that is a Wrappfile (`stages/prefix`), parsed; nil
    /// for one its Swift provides (`steam/client`) or none.
    func moduleStageFile(_ name: String, of module: ModuleFolder) throws(PlanError) -> Stage? {
        guard let path = module.manifest.stages?.first(where: { ($0 as NSString).lastPathComponent.lowercased() == name.lowercased() })
        else { return nil }
        guard let text = try? String(contentsOf: module.file(path), encoding: .utf8) else {
            throw PlanError(description: "the \(module.manifest.id) module's \(path) can't be read")
        }
        do {
            guard let stage = try WrappfileParser.parse(text).stage(named: name) else {
                throw PlanError(description: "the \(module.manifest.id) module's \(path) has no stage called \(name)")
            }
            return stage
        } catch let error as WrappfileError {
            throw PlanError(description: "the \(module.manifest.id) module's \(path): \(error)")
        } catch {
            throw PlanError(description: "the \(module.manifest.id) module's \(path): \(error)")
        }
    }

    /// A module's stage planned on its own (`wine/prefix`, as Wine's every
    /// prefix is made), at the version `constraint` picks: what the build
    /// makes the prefix with, and its layer is keyed on.
    public static func moduleStage(_ id: String, _ name: String, constraint: String?, modules: [ModuleFolder]) throws -> PlannedStage? {
        try moduleStages(id, name, constraint: constraint, modules: modules).last
    }

    /// A module's stage, after each module stage it's built from, in the
    /// order they're made (`wine/prefix`, then `steam/client`).
    public static func moduleStages(_ id: String, _ name: String, constraint: String?, modules: [ModuleFolder]) throws -> [PlannedStage] {
        guard let module = modules.first(where: { $0.manifest.id == id }) else { return [] }
        let manifest = try Manifest.decode(["format": 1, "id": "module/\(id)", "version": 1, "title": id,
                                            "editions": [["id": "module", "source": "download"]]])
        let planner = BuildPlanner(bundle: ProgramBundle(folder: module.folder, manifest: manifest), wrappfile: Wrappfile(), modules: modules)
        let context = Context(planner: planner, edition: manifest.editions[0], conditions: .thisMac, recorder: Recorder())
        var stages: [PlannedStage] = []
        var known: [String: StageModules] = [:]
        try context.planModuleStages(StageSource.module(id: id, constraint: constraint, stage: name), into: &stages, known: &known)
        return stages
    }

    /// A module's function's steps, planned in a stage with nothing but
    /// the module: what a builder with no plan of its own runs (cnc-ddraw
    /// for a Steam or Big Fish DirectDraw game, until their editions have
    /// stages).
    public static func functionSteps(_ id: String, _ function: String, modules: [ModuleFolder]) throws -> [PlannedStep] {
        guard let module = modules.first(where: { $0.manifest.id == id }) else { return [] }
        let manifest = try Manifest.decode(["format": 1, "id": "module/\(id)", "version": 1, "title": id,
                                            "editions": [["id": "module", "source": "download"]]])
        let file = try WrappfileParser.parse("FROM scratch AS only\nUSE \(id)\nDO \(id).\(function)\n")
        let planner = BuildPlanner(bundle: ProgramBundle(folder: module.folder, manifest: manifest), wrappfile: file, modules: modules)
        let context = Context(planner: planner, edition: manifest.editions[0], conditions: .thisMac, recorder: Recorder())
        guard let stage = file.stage(named: "only") else { return [] }
        return try context.plan(stage, globals: try context.globalScope(), inheriting: [:]).stage.steps
    }

    /// The Wrappfile's global `CONST`s as `editionID` has them
    /// (`install-dir`), for its lock.
    public func globalConstants(edition editionID: String) -> [String: String] {
        guard let edition = bundle.manifest.editions.first(where: { $0.id == editionID }),
              let scope = try? Context(planner: self, edition: edition, conditions: .thisMac, recorder: Recorder()).globalScope()
        else { return [:] }
        var values: [String: String] = [:]
        for (name, binding) in scope.frames.first ?? [:] {
            if case .const(let value) = binding, let text = value.text { values[name] = text }
        }
        return values
    }

    /// What planning records as it goes: the edition's inputs read, and the
    /// files steps name.
    final class Recorder: @unchecked Sendable {
        var usedInputs: Set<String> = []
        var files: [String: URL] = [:]
    }

    /// A stage's modules, by the name it knows each by, and the version of
    /// each it has; and what's recorded rather than run, inherited through
    /// `FROM` as the modules are: its launch, volumes and `APP`.
    struct StageModules {
        var aliases: [String: String] = [:]
        var versions: [String: String] = [:]
        var launch: RecordedLaunch?
        var volumes: [RecordedLaunch.Volume] = []
        var app = RecordedApp()
        /// Built from the old wrapp (`FROM previous`), whose launch it keeps.
        var fromPrevious = false
    }

    // MARK: - Working it out

    struct Context {
        let planner: BuildPlanner
        let edition: Manifest.Edition
        let conditions: BuildConditions
        let recorder: Recorder

        /// What a name is bound to in a scope.
        enum Binding {
            /// An `INPUT`: the edition's input, by name, for a global one;
            /// a value for a function's; nil when nothing gives it one.
            case input(WrappValue?, editionInput: String?, secret: Bool)
            case const(WrappValue)
            /// A `VAR`: nil until something sets it.
            case variable(WrappValue?)
        }

        /// What a stage, function or branch knows as it's planned.
        struct Scope {
            var modules = StageModules()
            /// Innermost last: the file's, a stage's or function's, then each
            /// branch's.
            var frames: [[String: Binding]] = [[:]]
            /// In a module's function: the module, `self`.
            var module: ModuleFolder?
            /// In a function, which reads its caller's values only through
            /// its own `INPUT`s, and those declared where it's defined.
            var inFunction = false
            /// The stages planned before this one, with their modules: where
            /// a `COPY --from=<stage>` path is.
            var otherStages: [String: StageModules] = [:]

            func binding(_ name: String) -> Binding? {
                for frame in frames.reversed() {
                    if let found = frame[name] { return found }
                }
                return nil
            }

            mutating func declare(_ name: String, _ binding: Binding) {
                frames[frames.count - 1][name] = binding
            }

            /// Sets the innermost `VAR` called `name`; false when there's none.
            mutating func set(_ name: String, _ value: WrappValue) -> Bool {
                for index in frames.indices.reversed() {
                    if case .variable = frames[index][name] {
                        frames[index][name] = .variable(value)
                        return true
                    }
                    if frames[index][name] != nil { return false }
                }
                return false
            }

            var moduleIDs: Set<ModuleID> { Set(modules.aliases.values.map(ModuleID.init(rawValue:))) }
        }

        /// The file's `INPUT`s, `CONST`s and `VAR`s, in order.
        func globalScope() throws(PlanError) -> Scope {
            var scope = Scope()
            for instruction in planner.wrappfile.globals {
                try declare(instruction, in: &scope, origin: "Wrappfile:\(instruction.line)")
            }
            return scope
        }

        /// The stages `name` needs, dependencies first.
        func collect(_ name: String, into order: inout [String]) throws(PlanError) {
            guard !order.contains(name) else { return }
            guard let stage = planner.wrappfile.stage(named: name) else {
                throw PlanError(description: "the Wrappfile has no stage called \(name)")
            }
            if case .stage(let parent) = stage.from, parent != "previous" {
                try collect(parent, into: &order)
            }
            for instruction in stage.body.flatMap(\.instructions) where instruction.keyword == "COPY" {
                if let from = instruction.option("from")?.value?.raw, planner.wrappfile.stage(named: from) != nil {
                    try collect(from.lowercased(), into: &order)
                }
            }
            order.append(name)
        }

        func plan(_ stage: Stage, globals: Scope, inheriting: [String: StageModules]) throws(PlanError) -> (stage: PlannedStage, modules: StageModules) {
            var scope = globals
            scope.frames.append([:])
            scope.otherStages = inheriting
            switch stage.from {
            case .stage("previous"): scope.modules.fromPrevious = true
            case .stage(let parent): scope.modules = inheriting[parent] ?? StageModules()
            case .module(let id, let constraint, let moduleStage):
                if let inherited = inheriting["\(id.lowercased())/\(moduleStage)"] {
                    scope.modules = inherited
                } else {
                    try addModule(id, constraint: constraint, as: nil, to: &scope, origin: "Wrappfile:\(stage.line)")
                }
            case .scratch: break
            }
            var steps: [PlannedStep] = []
            try expand(stage.body, scope: &scope, origin: "Wrappfile", into: &steps)
            let (run, emits) = PlannedStage.separatingEmits(steps)
            let planned = PlannedStage(name: stage.name ?? "", from: stage.from,
                                       modules: Array(Set(scope.modules.aliases.values)).sorted(), steps: run, emits: emits)
            return (planned, scope.modules)
        }

        /// A module's stage, planned with the module as `self` and at the
        /// version the bundle's `FROM` picked, which its own `USE` of the
        /// module takes.
        /// The module stage `from` names, if it's one that is a Wrappfile, and
        /// each it's built from before it, each planned once: added to
        /// `stages` and `known`, by `<module>/<stage>`.
        func planModuleStages(_ from: StageSource, into stages: inout [PlannedStage],
                              known: inout [String: StageModules]) throws(PlanError) {
            guard case .module(let id, let constraint, let name) = from, let module = planner.modules[id.lowercased()],
                  let found = try planner.moduleStageFile(name, of: module) else { return }
            let key = "\(module.manifest.id)/\(name)"
            guard known[key] == nil else { return }
            try planModuleStages(found.from, into: &stages, known: &known)
            let planned = try planModuleStage(found, named: key, module: module, constraint: constraint, inheriting: known)
            known[key] = planned.modules
            stages.append(planned.stage)
        }

        func planModuleStage(_ stage: Stage, named name: String, module: ModuleFolder,
                             constraint: String?, inheriting: [String: StageModules] = [:]) throws(PlanError) -> (stage: PlannedStage, modules: StageModules) {
            var scope = Scope()
            if case .module(let parent, _, let parentStage) = stage.from, let inherited = inheriting["\(parent.lowercased())/\(parentStage)"] {
                scope.modules = inherited
            }
            scope.module = module
            try addModule(module.manifest.id, constraint: constraint, as: nil, to: &scope, origin: name)
            var steps: [PlannedStep] = []
            let path = module.manifest.stages?.first { ($0 as NSString).lastPathComponent == stage.name } ?? "stages/\(stage.name ?? "")"
            try expand(stage.body, scope: &scope, origin: "\(module.manifest.id)/\(path)", into: &steps)
            let (run, emits) = PlannedStage.separatingEmits(steps)
            let planned = PlannedStage(name: name, from: stage.from, modules: Array(Set(scope.modules.aliases.values)).sorted(), steps: run,
                                       module: module.manifest.id, emits: emits)
            return (planned, scope.modules)
        }

        func addModule(_ id: String, constraint: String?, as alias: String?, to scope: inout Scope, origin: String) throws(PlanError) {
            let id = id.lowercased()
            let module = planner.modules[id]
            let versions = (module?.manifest.versions ?? []).map(\.version)
                .filter { version in constraint.map { WrappfileChecker.matches(version, $0) } ?? true }
                .sorted { WrappfileChecker.compare($0, $1) == .orderedAscending }
            if let had = scope.modules.versions[id], let constraint, !WrappfileChecker.matches(had, constraint) {
                throw PlanError(description: "\(origin): the stage has \(id) \(had) already, which isn't \(constraint)")
            }
            if scope.modules.versions[id] == nil, let picked = versions.last { scope.modules.versions[id] = picked }
            scope.modules.aliases[(alias ?? WrappfileChecker.ownName(id)).lowercased()] = id
            for dependency in module?.manifest.dependsOn ?? [] {
                let (dependencyID, dependencyConstraint) = WrappfileChecker.splitConstraint(dependency)
                if !scope.modules.aliases.values.contains(dependencyID.lowercased()) {
                    try addModule(dependencyID, constraint: dependencyConstraint, as: nil, to: &scope, origin: origin)
                }
            }
        }

        func expand(_ body: [Step], scope: inout Scope, origin: String, into steps: inout [PlannedStep]) throws(PlanError) {
            for step in body {
                switch step {
                case .instruction(let instruction):
                    try expand(instruction, scope: &scope, origin: origin, into: &steps)
                case .layer(let inner, _):
                    try expand(inner, scope: &scope, origin: origin, into: &steps)
                case .conditional(let branches):
                    for branch in branches {
                        if let condition = branch.condition {
                            guard try holds(condition, scope: scope, origin: Self.locate(origin, line: branch.line)) else { continue }
                        }
                        // A branch is a scope: its declarations are its own, and
                        // a SET of an outer VAR changes it. What it records (a
                        // LAUNCH, a VOLUME) and the modules it uses are the
                        // stage's, as the branch taken decides them.
                        var inner = scope
                        inner.frames.append([:])
                        try expand(branch.steps, scope: &inner, origin: origin, into: &steps)
                        inner.frames.removeLast()
                        scope.frames = inner.frames
                        scope.modules = inner.modules
                        break
                    }
                }
            }
        }

        func expand(_ instruction: Instruction, scope: inout Scope, origin: String,
                    into steps: inout [PlannedStep]) throws(PlanError) {
            let at = Self.locate(origin, line: instruction.line)
            switch instruction.keyword {
            case "INPUT", "CONST", "VAR", "SET":
                try declare(instruction, in: &scope, origin: at)
            case "USE":
                let words = instruction.arguments.map(\.raw)
                let (id, constraint) = WrappfileChecker.splitConstraint(words.first ?? "")
                try addModule(id, constraint: constraint, as: words.count == 3 ? words[2] : nil, to: &scope, origin: at)
            case "DO":
                try expandFunction(instruction, scope: &scope, origin: at, into: &steps)
            case _ where InstructionSpec.recorded.contains(instruction.keyword):
                try record(instruction, scope: &scope, origin: at)
            default:
                let module = instruction.moduleAlias.map { scope.modules.aliases[$0] ?? $0 }
                let spec = spec(of: instruction, module: module)
                let stageModules = scope.moduleIDs
                var options: [String: [String]] = [:]
                for option in instruction.options {
                    var role = spec?.role(ofOption: option.name) ?? .text
                    if instruction.keyword == "COPY", option.name == "from" { role = .input }
                    var value = try option.value.map { word throws(PlanError) in
                        try substitute(word, in: scope, origin: at, as: role)
                    } ?? ""
                    if option.name == "mount" {
                        value = try plannedMount(value, scope: scope, modules: stageModules, origin: at)
                    } else if role != .input {
                        value = try fullForm(value, role: role, scope: scope, modules: stageModules, origin: at)
                    }
                    options[moduleOptionName(option.name, scope: scope), default: []].append(value)
                }
                var arguments: [String] = []
                for (index, word) in instruction.arguments.enumerated() {
                    let role = spec?.role(ofArgument: index) ?? .text
                    let value = try substitute(word, in: scope, origin: at, as: role)
                    if role == .copySource, instruction.option("from") == nil {
                        // Without --from, a file of the bundle's or a module's.
                        arguments.append(try fileFullForm(value, scope: scope, origin: at))
                        continue
                    }
                    if role == .copySource {
                        // A path in the stage copied from is that stage's; one in an input is the input's.
                        guard let from = instruction.option("from")?.value?.raw.lowercased(),
                              let copied = scope.otherStages[from] else {
                            arguments.append(value)
                            continue
                        }
                        let modules = Set(copied.aliases.values.map(ModuleID.init(rawValue:)))
                        arguments.append(try fullForm(value, role: .location, scope: scope, modules: modules, origin: at))
                        continue
                    }
                    arguments.append(role == .input ? value : try fullForm(value, role: role, scope: scope, modules: stageModules, origin: at))
                }
                steps.append(PlannedStep(instruction: instruction.name, module: module, options: options,
                                         arguments: arguments, name: options["name"]?.first, origin: at))
            }
        }

        /// `INPUT`, `CONST`, `VAR` or `SET`, in `scope`.
        func declare(_ instruction: Instruction, in scope: inout Scope, origin: String) throws(PlanError) {
            guard let declaration = Declaration(instruction) else { return }
            let name = declaration.name
            switch declaration.kind {
            case .input:
                let secret = instruction.option("secret") != nil
                let fallback = try declaration.value.map { word throws(PlanError) in try evaluate(word, in: scope, origin: origin) }
                if scope.inFunction {
                    // Given by DO (bound before the body runs), or else read
                    // from the caller by name, or else the default.
                    if case .input(let given?, let editionInput, _) = scope.binding(name) {
                        scope.declare(name, .input(given, editionInput: editionInput, secret: secret))
                    } else {
                        scope.declare(name, .input(fallback, editionInput: nil, secret: secret))
                    }
                } else if let input = edition.input(name) {
                    let value: WrappValue
                    if input.type == .choice {
                        value = .text(conditions.choices[name] ?? input.default ?? "")
                    } else {
                        value = .object(input.fields.mapValues(WrappValue.text))
                    }
                    scope.declare(name, .input(value, editionInput: name, secret: secret))
                } else if let given = conditions.choices[name] {
                    scope.declare(name, .input(.text(given), editionInput: nil, secret: secret))
                } else {
                    scope.declare(name, .input(fallback, editionInput: nil, secret: secret))
                }
            case .const:
                guard let word = declaration.value else { return }
                scope.declare(name, .const(try evaluate(word, in: scope, origin: origin)))
            case .variable:
                scope.declare(name, .variable(try declaration.value.map { word throws(PlanError) in
                    try evaluate(word, in: scope, origin: origin)
                }))
            case .set:
                guard let word = declaration.value else { return }
                let value = try evaluate(word, in: scope, origin: origin)
                if !scope.set(name, value) {
                    throw PlanError(description: "\(origin): SET \(name), but there's no VAR called that")
                }
            }
        }

        func expandFunction(_ instruction: Instruction, scope: inout Scope, origin: String,
                            into steps: inout [PlannedStep]) throws(PlanError) {
            guard let name = instruction.arguments.first?.raw.lowercased() else { return }
            var inner = Scope(modules: scope.modules, frames: [[:]], module: nil, inFunction: true, otherStages: scope.otherStages)
            let function: WrappfileFunction
            let source: String
            if let dot = name.firstIndex(of: ".") {
                let alias = String(name[..<dot])
                let functionName = String(name[name.index(after: dot)...])
                let module: ModuleFolder?
                if alias == "self" {
                    module = scope.module
                } else if alias == "module" {
                    module = nil
                } else {
                    module = scope.modules.aliases[alias].flatMap { planner.modules[$0] }
                }
                guard let module, let path = module.manifest.functions?.first(where: {
                          ($0 as NSString).lastPathComponent.lowercased() == functionName
                      }),
                      let text = try? String(contentsOf: module.file(path), encoding: .utf8),
                      let file = try? WrappfileParser.parse(text), let found = file.function(named: functionName) else {
                    throw PlanError(description: "\(origin): no function \(name)")
                }
                function = found
                source = "\(module.manifest.id)/\(path)"
                inner.module = module
            } else {
                guard let found = planner.wrappfile.function(named: name) else {
                    throw PlanError(description: "\(origin): no function \(name)")
                }
                function = found
                source = "Wrappfile"
                inner.module = scope.module
                // A function sees what's declared where it's defined: a
                // bundle's, the file's globals, the first of any scope's
                // frames. A module's sees its own file's, which declares none.
                inner.frames = [scope.frames.first ?? [:], [:]]
            }
            // Its INPUTs: the DO's options; its own default otherwise. Never
            // a caller's value that happens to have the same name.
            for parameter in function.parameters {
                if let option = instruction.option(parameter.name) {
                    let value = try option.value.map { word throws(PlanError) in try evaluate(word, in: scope, origin: origin) } ?? .text("")
                    var editionInput: String?
                    if let reference = option.value?.lone, reference.root == "input", reference.segments.count == 2,
                       case .input(_, let fromEdition, _) = scope.binding(reference.plainPath.first ?? "") {
                        editionInput = fromEdition
                    }
                    inner.declare(parameter.name, .input(value, editionInput: editionInput, secret: false))
                }
            }
            for option in instruction.options where option.name != "name" && !function.parameters.contains(where: { $0.name == option.name }) {
                throw PlanError(description: "\(origin): DO \(name) takes no --\(option.name)")
            }
            try expand(function.body, scope: &inner, origin: "\(source) from \(origin)", into: &steps)
            // What a function records (its LAUNCH, VOLUMEs, APP) and the
            // modules it USEs are the calling stage's, as if written there.
            scope.modules = inner.modules
        }

        /// `LAUNCH`, `VOLUME` or `APP`: recorded with the stage, in full
        /// form, rather than run. The last `LAUNCH` a stage reaches wins,
        /// fallback and all; volumes build up, and `--remove` takes one off.
        func record(_ instruction: Instruction, scope: inout Scope, origin: String) throws(PlanError) {
            guard let spec = InstructionSpec.core[instruction.keyword] else { return }
            let modules = scope.moduleIDs
            var options: [String: String] = [:]
            var environment: [String: String] = [:]
            for option in instruction.options {
                let key = moduleOptionName(option.name, scope: scope)
                let role = moduleOptionRole(key, of: instruction.keyword) ?? spec.role(ofOption: option.name)
                let text = try option.value.map { word throws(PlanError) in try substitute(word, in: scope, origin: origin, as: role) } ?? ""
                if text.contains("${input.") {
                    throw PlanError(description: "\(origin): a secret can't be recorded in the app: \(option.name)")
                }
                if option.name == "env" {
                    let pair = text.split(separator: "=", maxSplits: 1)
                    environment[String(pair[0])] = pair.count > 1 ? String(pair[1]) : ""
                } else {
                    options[key] = try fullForm(text, role: role, scope: scope, modules: modules, origin: origin)
                }
            }
            var arguments: [String] = []
            for (index, word) in instruction.arguments.enumerated() {
                let role = spec.role(ofArgument: index)
                let text = try substitute(word, in: scope, origin: origin, as: role)
                arguments.append(try fullForm(text, role: role, scope: scope, modules: modules, origin: origin))
            }
            switch instruction.keyword {
            case "LAUNCH":
                guard let program = arguments.first else { return }
                let fallback = options.removeValue(forKey: "fallback")
                if let window = options["wine.window"], !["fullscreen", "windowed"].contains(window) {
                    throw PlanError(description: "\(origin): --wine.window=\(window): it's fullscreen or windowed, or left out for what the program asks for")
                }
                let launch = RecordedLaunch(program: program, arguments: Array(arguments.dropFirst()), environment: environment,
                                            options: options, fallback: fallback, format: RecordedLaunch.currentFormat)
                try checkLaunch(launch, origin: origin)
                scope.modules.launch = launch
            case "VOLUME":
                guard let name = arguments.first else { return }
                if options.removeValue(forKey: "remove") != nil {
                    guard scope.modules.volumes.contains(where: { $0.name == name }) else {
                        throw PlanError(description: "\(origin): VOLUME --remove \(name), but the stage has no volume called that")
                    }
                    scope.modules.volumes.removeAll { $0.name == name }
                } else if arguments.count == 2 {
                    scope.modules.volumes.removeAll { $0.name == name }
                    scope.modules.volumes.append(RecordedLaunch.Volume(name: name, location: arguments[1], options: options))
                }
            default:
                if let icon = options["icon"] { scope.modules.app.icon = icon }
                if let name = options["name"] { scope.modules.app.name = name }
                if let id = options["default-id"] { scope.modules.app.defaultID = id }
            }
        }

        /// What a launch must say for the module that starts it.
        func checkLaunch(_ launch: RecordedLaunch, origin: String) throws(PlanError) {
            func checkGraphics(_ what: String) throws(PlanError) {
                let graphics = launch.options["wine.graphics"]
                guard let graphics, ["direct-draw", "direct-3d", "unknown"].contains(graphics) else {
                    throw PlanError(description: "\(origin): \(what) says what it draws with: --wine.graphics=direct-draw, direct-3d or unknown")
                }
            }
            switch launch.launcher(planner.pathTypes) {
            case .wine?:
                try checkGraphics("a Wine launch")
            case .steam?, .bigFish?:
                // Steam, or Big Fish's DRM, starts a Windows game in the app's
                // Wine, so the launch says what it draws with too, and the
                // program that's started.
                let module = launch.launcher(planner.pathTypes)?.rawValue ?? ""
                let what = module == "steam" ? "a Steam launch" : "a Big Fish launch"
                try checkGraphics(what)
                guard launch.options["\(module).exe"]?.hasPrefix("wine:") == true else {
                    throw PlanError(description: "\(origin): \(what) names the program it starts: --\(module).exe=<its path in Wine>")
                }
                guard launch.arguments.isEmpty else {
                    throw PlanError(description: "\(origin): \(what) takes no arguments")
                }
            case .scummvm?:
                guard !launch.arguments.isEmpty else {
                    throw PlanError(description: "\(origin): a ScummVM launch names its game: LAUNCH <folder> <game id>")
                }
            default:
                break
            }
        }

        /// `origin` with `line` after its file: `nancy-drew/functions/patch:30
        /// from Wrappfile:16`.
        static func locate(_ origin: String, line: Int) -> String {
            guard let from = origin.range(of: " from ") else { return "\(origin):\(line)" }
            return "\(origin[..<from.lowerBound]):\(line)\(origin[from.lowerBound...])"
        }

        // MARK: - Paths and modules' additions

        /// The spec of `instruction`, a core one or `module`'s.
        func spec(of instruction: Instruction, module: String?) -> InstructionSpec? {
            guard let module else { return InstructionSpec.core[instruction.keyword] }
            return planner.modules[module].map(planner.declarations)?.instruction(instruction.name)
        }

        /// What a module's option on a core instruction is (`steam.exe`, a
        /// location); nil for a core option, or a module's that is text.
        func moduleOptionRole(_ key: String, of keyword: String) -> InstructionSpec.Role? {
            guard let dot = key.firstIndex(of: ".") else { return nil }
            let module = planner.modules[String(key[..<dot])]
            return module.map(planner.declarations)?.coreOptionRoles[keyword]?[String(key[key.index(after: dot)...])]
        }

        /// `--<alias>.<option>` keyed by the module's id: `--w.drive` after
        /// `USE wine AS w` is `wine.drive`, so nothing after planning sees an
        /// alias.
        func moduleOptionName(_ name: String, scope: Scope) -> String {
            guard let dot = name.firstIndex(of: ".") else { return name }
            let alias = name[..<dot].lowercased()
            return "\(scope.modules.aliases[alias] ?? alias).\(name[name.index(after: dot)...])"
        }

        /// A `--mount=` value with its fields' aliases made ids and its
        /// paths and files in full form.
        func plannedMount(_ value: String, scope: Scope, modules: Set<ModuleID>, origin: String) throws(PlanError) -> String {
            var fields: [String] = []
            for part in value.split(separator: ",", omittingEmptySubsequences: false) {
                let pair = part.split(separator: "=", maxSplits: 1)
                let key = moduleOptionName(String(pair[0]), scope: scope)
                guard pair.count > 1 else {
                    fields.append(key)
                    continue
                }
                var text = String(pair[1])
                if let role = InstructionSpec.mountFieldRoles[key] {
                    text = try fullForm(text, role: role, scope: scope, modules: modules, origin: origin)
                }
                fields.append("\(key)=\(text)")
            }
            return fields.joined(separator: ",")
        }

        /// `path` in its full form (`C:/x` as `wine:C:/x`, `assets/disc.iss`
        /// as `bundle:assets/disc.iss`), for the stage's `modules`: what `sc
        /// bundle plan`, layer keys and builders see, so each says which type
        /// took a path. The stage-dependent checks the checker can't make in a
        /// function's body are made here.
        func fullForm(_ path: String, role: InstructionSpec.Role, scope: Scope, modules: Set<ModuleID>,
                      origin: String) throws(PlanError) -> String {
            let pathRole: PathType.Role
            switch role {
            case .location, .copySource: pathRole = .location
            case .program: pathRole = .program
            case .file: return try fileFullForm(path, scope: scope, origin: origin)
            case .input, .text: return path
            }
            if let (type, _) = planner.pathTypes.split(path) {
                guard type.roles.contains(pathRole) else {
                    throw PlanError(description: "\(origin): \(path): a \(type.name): path isn't a \(pathRole.rawValue)")
                }
                guard modules.contains(type.module) else {
                    throw PlanError(description: "\(origin): \(path): \(type.name): paths are \(type.module)'s, which the stage doesn't have")
                }
                return path
            }
            guard let form = PathTypeRegistry.shortForm(of: path) else { return path }
            if form == .folder, pathRole == .location {
                if WrappfileChecker.leavesTheApp(path) {
                    throw PlanError(description: "\(origin): \(path): it goes above the app's top level")
                }
                return path
            }
            let claiming = planner.pathTypes.claiming(form, as: pathRole, among: modules)
            switch claiming.count {
            case 1:
                return claiming[0].fullForm(path)
            case 0:
                let uses = modules.map(\.rawValue).sorted().joined(separator: ", ")
                let what = form == .driveLetter ? "\(path.prefix(2)) paths" : "a folder as a \(pathRole.rawValue)"
                throw PlanError(description: "\(origin): \(path): no module of this stage handles \(what) (it uses \(uses))")
            default:
                throw PlanError(description: "\(origin): \(path): both \(claiming.map(\.name).joined(separator: " and ")) take it here; write it in full")
            }
        }

        /// A file the build reads, in full form: a relative path is the
        /// bundle's, or in a module's function the module's; `module:<id>:/…`
        /// is another module's. Recorded with where it is, and refused when
        /// it isn't there (but for one a module's Swift provides).
        func fileFullForm(_ path: String, scope: Scope, origin: String) throws(PlanError) -> String {
            let fullForm: String
            let location: URL?
            if path.hasPrefix("bundle:") || path.hasPrefix("module:") || path.hasPrefix("/") {
                fullForm = path
            } else if let module = scope.module {
                fullForm = "module:\(module.manifest.id):/\(path)"
            } else {
                fullForm = "bundle:\(path)"
            }
            if fullForm.hasPrefix("bundle:") {
                let relative = String(fullForm.dropFirst("bundle:".count))
                guard planner.hostPaths.allows(relative) else {
                    throw PlanError(description: "\(origin): \(fullForm): the build may not read it. "
                        + HostPaths.howToAllow(relative, of: "the bundle's manifest"))
                }
                location = planner.bundle.folder.appendingPathComponent(relative)
            } else if fullForm.hasPrefix("module:") {
                // `module:<id>:/<path>`: a namespaced id's `/` can't be
                // mistaken for the path's.
                let rest = fullForm.dropFirst("module:".count)
                guard let separator = rest.range(of: ":/") else {
                    throw PlanError(description: "\(origin): \(fullForm): a module's file is written module:<id>:/<path> now")
                }
                let id = String(rest[..<separator.lowerBound]).lowercased()
                let file = String(rest[separator.upperBound...])
                guard let module = planner.modules[id] else {
                    throw PlanError(description: "\(origin): \(fullForm): there's no \(id) module")
                }
                if planner.declarations(module).providedFiles.contains(file) { return fullForm }
                guard HostPaths(allowed: module.manifest.allowPaths ?? []).allows(file) else {
                    throw PlanError(description: "\(origin): \(fullForm): the build may not read it. "
                        + HostPaths.howToAllow(file, of: "the \(id) module's module.yaml"))
                }
                location = module.file(file)
            } else {
                return path
            }
            if let location {
                guard FileManager.default.fileExists(atPath: location.path) else {
                    throw PlanError(description: "\(origin): \(fullForm): there's no such file")
                }
                recorder.files[fullForm] = location
            }
            return fullForm
        }

        // MARK: - Values

        func holds(_ condition: Condition, scope: Scope, origin: String) throws(PlanError) -> Bool {
            let left = try substitute(condition.left, in: scope, origin: origin, as: .text)
            let right = try substitute(condition.right, in: scope, origin: origin, as: .text)
            switch condition.comparison {
            case .equals: return left == right
            case .notEquals: return left != right
            }
        }

        /// A declaration's right-hand side: a lone `${…}` keeps its value as
        /// it is (an object stays one); anything else is text.
        func evaluate(_ word: Word, in scope: Scope, origin: String) throws(PlanError) -> WrappValue {
            if !word.quoted, let reference = word.lone {
                return try value(of: reference, in: scope, origin: origin, whole: true)
            }
            return .text(try substitute(word, in: scope, origin: origin, as: .text))
        }

        /// A word as text. A whole input where an input is taken is its
        /// token (`input:disc-1`); a secret input's reference is left as it
        /// is, for the builder to fill in, so it never reaches a step's text.
        func substitute(_ word: Word, in scope: Scope, origin: String, as role: InstructionSpec.Role) throws(PlanError) -> String {
            if role == .input, let reference = word.lone, reference.root == "input", reference.segments.count == 2,
               let name = reference.plainPath.first, case .input(_, let editionInput?, _) = scope.binding(name) {
                recorder.usedInputs.insert(editionInput)
                if case .input(.text?, _, _)? = scope.binding(name) {
                    throw PlanError(description: "\(origin): ${\(reference)} is a choice, not an input to take things from")
                }
                return PlannedStep.inputToken(editionInput)
            }
            var result = ""
            for part in word.parts {
                switch part {
                case .text(let text):
                    result += text
                case .substitution(let expression):
                    let reference: Reference
                    do {
                        reference = try Reference.parse(expression)
                    } catch {
                        throw PlanError(description: "\(origin): \(error.message)")
                    }
                    if reference.root == "input", let name = reference.plainPath.first,
                       case .input(_, _, true)? = scope.binding(name) {
                        result += "${\(expression)}"
                        continue
                    }
                    switch try value(of: reference, in: scope, origin: origin, whole: false) {
                    case .text(let text): result += text
                    default:
                        throw PlanError(description: "\(origin): ${\(expression)} isn't text: name a field of it")
                    }
                }
            }
            return result
        }

        /// What `reference` names.
        func value(of reference: Reference, in scope: Scope, origin: String, whole: Bool) throws(PlanError) -> WrappValue {
            let at = "\(origin): ${\(reference)}"
            var remaining = Array(reference.segments.dropFirst())
            func nextName() throws(PlanError) -> String {
                guard case .name(let name)? = remaining.first else {
                    throw PlanError(description: "\(at): a name is missing")
                }
                remaining.removeFirst()
                return name
            }
            var current: WrappValue
            switch reference.root {
            case "input":
                let name = try nextName()
                guard case .input(let value, let editionInput, _)? = scope.binding(name) else {
                    throw PlanError(description: "\(at): no INPUT called \(name) here")
                }
                if let editionInput { recorder.usedInputs.insert(editionInput) }
                guard let value else {
                    throw PlanError(description: "\(at): manifest.yaml's edition \(edition.id) gives no \(name), and the INPUT has no default")
                }
                current = value
            case "const", "var":
                let name = try nextName()
                switch scope.binding(name) {
                case .const(let value) where reference.root == "const":
                    current = value
                case .variable(let value) where reference.root == "var":
                    guard let value else { throw PlanError(description: "\(at): VAR \(name) is read before anything sets it") }
                    current = value
                default:
                    throw PlanError(description: "\(at): no \(reference.root.uppercased()) called \(name) here")
                }
            case "platform":
                switch try nextName() {
                case "arch": current = .text(conditions.arch)
                case "macos": current = .text(String(conditions.macos))
                case let other: throw PlanError(description: "\(at): platform has no \(other) (arch, macos)")
                }
            case "program":
                throw PlanError(description: "\(at): program is only read by a signal")
            case "self":
                guard let module = scope.module else { throw PlanError(description: "\(at): self is only in a module's files") }
                current = try moduleValue(module, remaining: &remaining, scope: scope, at: at)
            case "module":
                let name = try nextName()
                guard let id = scope.modules.aliases[name.lowercased()], let module = planner.modules[id] else {
                    throw PlanError(description: "\(at): the stage has no module called \(name)")
                }
                current = try moduleValue(module, remaining: &remaining, scope: scope, at: at)
            case let root:
                guard let id = scope.modules.aliases[root.lowercased()], let module = planner.modules[id] else {
                    throw PlanError(description: "\(at): \(root) is no namespace, and no module of the stage")
                }
                current = try moduleValue(module, remaining: &remaining, scope: scope, at: at)
            }
            return try walk(current, remaining, scope: scope, origin: origin, at: at)
        }

        /// A module's `version`, or a table of its `data`.
        func moduleValue(_ module: ModuleFolder, remaining: inout [Reference.Segment], scope: Scope, at: String) throws(PlanError) -> WrappValue {
            guard case .name(let field)? = remaining.first else { throw PlanError(description: "\(at): name version or data") }
            remaining.removeFirst()
            switch field {
            case "version":
                let id = module.manifest.id.lowercased()
                guard let version = scope.modules.versions[id] ?? module.manifest.versions.last?.version else {
                    throw PlanError(description: "\(at): \(id) has no version")
                }
                return .text(version)
            case "data":
                guard case .name(let table)? = remaining.first else { throw PlanError(description: "\(at): name a table") }
                remaining.removeFirst()
                guard let file = module.manifest.data?.first(where: { ($0 as NSString).deletingPathExtension == table }) else {
                    throw PlanError(description: "\(at): \(module.manifest.id) has no data table \(table)")
                }
                do {
                    return try ModuleTables.shared.table(file, of: module)
                } catch {
                    throw PlanError(description: "\(at): \(module.manifest.id)'s \(file) couldn't be read: \(error)")
                }
            default:
                throw PlanError(description: "\(at): a module has version and data, not \(field)")
            }
        }

        /// `value` down `segments`: each a property, or an item of a list by
        /// its `id`, a bracket's key worked out first.
        func walk(_ value: WrappValue, _ segments: [Reference.Segment], scope: Scope, origin: String, at: String) throws(PlanError) -> WrappValue {
            var current = value
            for segment in segments {
                let key: String
                switch segment {
                case .name(let name): key = name
                case .key(let inner):
                    guard let text = try self.value(of: inner, in: scope, origin: origin, whole: false).text else {
                        throw PlanError(description: "\(at): [\(inner)] isn't text")
                    }
                    key = text
                }
                guard let next = current.member(key) else {
                    throw PlanError(description: "\(at): there's no \(key)")
                }
                current = next
            }
            return current
        }
    }
}

/// Modules' data tables, read once each, with their schemas' defaults
/// filled in.
nonisolated final class ModuleTables: @unchecked Sendable {
    static let shared = ModuleTables()
    private let lock = NSLock()
    private var cache: [URL: WrappValue] = [:]

    func table(_ file: String, of module: ModuleFolder) throws -> WrappValue {
        let url = module.file(file)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[url] { return cached }
        var data = try ModuleLoader.table(file, of: module)
        let schemaFile = module.file((file as NSString).deletingPathExtension + ".schema.json")
        if let schemaData = try? Data(contentsOf: schemaFile),
           let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] {
            data = SchemaDefaults.fill(data, schema: schema, root: schema)
        }
        let value = WrappValue(data)
        cache[url] = value
        return value
    }
}
