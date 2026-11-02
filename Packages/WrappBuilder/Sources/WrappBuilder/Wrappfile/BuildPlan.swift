//
//  BuildPlan.swift
//  WrappBuilder
//
//  An edition's build, worked out from its Wrappfile before anything runs.

import Foundation
import WrappModules

/// What a build of one edition runs, in order: the stages its target needs,
/// each with its steps, functions expanded, `${…}` substituted, `IF`s
/// decided for this build, and its modules' `assemble` steps after the
/// target's own. Worked out before anything runs (`BuildPlanner`), so a
/// mistake shows before a disc is copied, and the plan can be logged,
/// compared and keyed.
public nonisolated struct BuildPlan: Sendable, Equatable {
    public let edition: String
    /// Dependencies first; the last is the target.
    public let stages: [PlannedStage]

    public var target: PlannedStage? { stages.last }
}

public nonisolated struct PlannedStage: Sendable, Equatable {
    public let name: String
    public let from: StageSource
    /// The modules it has, by id, its dependencies' and `FROM`'s included.
    public let modules: [String]
    public let steps: [PlannedStep]
}

/// One step, ready to run: every value substituted.
public nonisolated struct PlannedStep: Sendable, Equatable, CustomStringConvertible {
    /// `RUN`, `COPY`, … for a core instruction, or `MOUNT` for `wine.MOUNT`.
    public let instruction: String
    /// The module whose instruction it is, by id; nil for the core's.
    public let module: String?
    /// Each option's values, in order (`--mount` may be given many times);
    /// a flag has one empty value.
    public let options: [String: [String]]
    public let arguments: [String]
    /// `--name`, when the step was given one.
    public let name: String?
    /// Where it was written: `Wrappfile:12`, or `nancy-drew/functions/patch:20`
    /// from `Wrappfile:16`.
    public let origin: String

    public func option(_ name: String) -> String? { options[name]?.first }
    public func has(_ name: String) -> Bool { options[name] != nil }

    public var description: String {
        let keyword = module.map { "\($0).\(instruction)" } ?? instruction
        let rendered = options.keys.sorted().flatMap { key in
            options[key, default: []].map { $0.isEmpty ? "--\(key)" : "--\(key)=\($0)" }
        }
        return ([keyword] + rendered + arguments).joined(separator: " ")
    }
}

/// What a build knows before it starts, which `IF`s and `${…}` read.
public nonisolated struct BuildConditions: Sendable {
    /// `arch`: `arm64` or `x86_64`, the Mac building the wrapp.
    public var arch: String
    /// `macos`: its major version.
    public var macos: Int
    /// The edition's choices, as chosen (or defaulted).
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

    public struct PlanError: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    public init(bundle: ProgramBundle, wrappfile: Wrappfile, modules: [ModuleFolder]) {
        self.bundle = bundle
        self.wrappfile = wrappfile
        self.modules = Dictionary(modules.map { ($0.manifest.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The plan for `editionID`, built for `conditions`. Nil for an edition
    /// with no `build`: a module's default stages build it.
    public func plan(edition editionID: String, conditions: BuildConditions) throws(PlanError) -> BuildPlan? {
        guard let edition = bundle.manifest.editions.first(where: { $0.id == editionID }) else {
            throw PlanError(description: "\(bundle.manifest.id) has no edition called \(editionID)")
        }
        guard let target = edition.build?.target else { return nil }
        var choices = Dictionary(uniqueKeysWithValues: (edition.choices ?? [:]).map { (WrappfileChecker.kebabCase($0.key), $0.value.default) })
        choices.merge(conditions.choices) { $1 }
        var effective = conditions
        effective.choices = choices
        let context = Context(planner: self, edition: edition, conditions: effective)
        var order: [String] = []
        try context.collect(target, into: &order)
        var stages: [PlannedStage] = []
        var modulesByStage: [String: [String: String]] = [:]
        for name in order {
            guard let stage = wrappfile.stage(named: name) else {
                throw PlanError(description: "the Wrappfile has no stage called \(name)")
            }
            let planned = try context.plan(stage, inheriting: modulesByStage, isTarget: name == target)
            modulesByStage[name] = planned.aliases
            stages.append(planned.stage)
        }
        return BuildPlan(edition: editionID, stages: stages)
    }

    // MARK: - Working it out

    struct Context {
        let planner: BuildPlanner
        let edition: Manifest.Edition
        let conditions: BuildConditions

        var globals: [String: String] {
            var values: [String: String] = [:]
            for arg in planner.wrappfile.globalArgs {
                values[arg.name] = arg.value.map { (try? substitute($0, in: Scope(values: values), origin: "")) ?? $0.raw } ?? ""
            }
            return values
        }

        /// The stages `name` needs, dependencies first.
        func collect(_ name: String, into order: inout [String]) throws(PlanError) {
            guard !order.contains(name) else { return }
            guard let stage = planner.wrappfile.stage(named: name) else {
                throw PlanError(description: "the Wrappfile has no stage called \(name)")
            }
            if case .stage(let parent) = stage.from, parent != "base", parent != "previous" {
                try collect(parent, into: &order)
            }
            for instruction in stage.body.flatMap(\.instructions) where instruction.keyword == "COPY" {
                if let from = instruction.option("from")?.value?.raw, planner.wrappfile.stage(named: from) != nil {
                    try collect(from, into: &order)
                }
            }
            order.append(name)
        }

        /// What a stage knows as it's planned: its modules by alias, and the
        /// values its `${…}` read.
        struct Scope {
            var aliases: [String: String] = [:]
            var values: [String: String] = [:]
            /// In a module's function: the module whose data `${data.…}` reads.
            var dataModule: ModuleFolder?
            /// In a module's function, `assets/` is the module's.
            var assetsRoot: URL?
        }

        func plan(_ stage: Stage, inheriting: [String: [String: String]],
                  isTarget: Bool) throws(PlanError) -> (stage: PlannedStage, aliases: [String: String]) {
            var scope = Scope()
            switch stage.from {
            case .stage(let parent): scope.aliases = inheriting[parent] ?? [:]
            case .module(let id, _, _): addModule(id, as: nil, to: &scope)
            case .scratch: break
            }
            var steps: [PlannedStep] = []
            try expand(stage.body, scope: &scope, origin: "Wrappfile", into: &steps)
            if isTarget {
                // Each module's `assemble` steps, after the stage's own, with
                // the bundle's global install-dir.
                var assembleScope = scope
                assembleScope.values = globals
                for id in Set(scope.aliases.values).sorted() {
                    guard let module = planner.modules[id] else { continue }
                    for line in module.manifest.assemble ?? [] {
                        guard let parsed = try? WrappfileParser.parse("FROM scratch\n" + line) else {
                            throw PlanError(description: "the \(id) module's assemble step \(line) doesn't parse")
                        }
                        try expand(parsed.stages[0].body, scope: &assembleScope, origin: "\(id)/module.yaml (assemble)", into: &steps)
                    }
                }
            }
            let planned = PlannedStage(name: stage.name ?? "", from: stage.from,
                                       modules: Array(Set(scope.aliases.values)).sorted(), steps: steps)
            return (planned, scope.aliases)
        }

        func addModule(_ id: String, as alias: String?, to scope: inout Scope) {
            scope.aliases[alias ?? WrappfileChecker.ownName(id)] = id
            for dependency in planner.modules[id]?.manifest.dependsOn ?? [] {
                let dependencyID = WrappfileChecker.splitConstraint(dependency).id
                if !scope.aliases.values.contains(dependencyID) { addModule(dependencyID, as: nil, to: &scope) }
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
                    for branch in branches where try branch.condition.map({ condition throws(PlanError) in
                        try holds(condition, scope: scope, origin: Self.locate(origin, line: branch.line))
                    }) ?? true {
                        var inner = scope
                        try expand(branch.steps, scope: &inner, origin: origin, into: &steps)
                        break
                    }
                }
            }
        }

        func expand(_ instruction: Instruction, scope: inout Scope, origin: String,
                    into steps: inout [PlannedStep]) throws(PlanError) {
            let at = Self.locate(origin, line: instruction.line)
            switch instruction.keyword {
            case "ARG":
                guard let word = instruction.arguments.first else { return }
                let declaration = WrappfileParser.argDeclaration(word, line: instruction.line)
                if scope.dataModule != nil {
                    // A function's parameter: given by DO, or its default.
                    if scope.values[declaration.name] == nil, let value = declaration.value {
                        scope.values[declaration.name] = try substitute(value, in: scope, origin: at)
                    }
                } else if let value = conditions.choices[declaration.name] ?? globals[declaration.name] {
                    scope.values[declaration.name] = value
                }
            case "USE":
                let words = instruction.arguments.map(\.raw)
                let id = WrappfileChecker.splitConstraint(words.first ?? "").id
                addModule(id, as: words.count == 3 ? words[2] : nil, to: &scope)
            case "DO":
                try expandFunction(instruction, scope: scope, origin: at, into: &steps)
            default:
                var options: [String: [String]] = [:]
                for option in instruction.options {
                    let value = try option.value.map { word throws(PlanError) in try substitute(word, in: scope, origin: at) } ?? ""
                    options[option.name, default: []].append(value)
                }
                let arguments = try instruction.arguments.map { word throws(PlanError) in try substitute(word, in: scope, origin: at) }
                let module = instruction.moduleAlias.map { scope.aliases[$0] ?? $0 }
                steps.append(PlannedStep(instruction: instruction.name, module: module, options: options,
                                         arguments: arguments, name: options["name"]?.first, origin: at))
            }
        }

        func expandFunction(_ instruction: Instruction, scope: Scope, origin: String,
                            into steps: inout [PlannedStep]) throws(PlanError) {
            guard let name = instruction.arguments.first?.raw else { return }
            var inner = Scope(aliases: scope.aliases, values: [:], dataModule: nil, assetsRoot: scope.assetsRoot)
            let function: WrappfileFunction
            let source: String
            if let dot = name.firstIndex(of: ".") {
                let alias = String(name[..<dot])
                let functionName = String(name[name.index(after: dot)...])
                guard let id = scope.aliases[alias], let module = planner.modules[id],
                      let path = module.manifest.functions?.first(where: { ($0 as NSString).lastPathComponent == functionName }),
                      let text = try? String(contentsOf: module.file(path), encoding: .utf8),
                      let file = try? WrappfileParser.parse(text), let found = file.function(named: functionName) else {
                    throw PlanError(description: "\(origin): no function \(name)")
                }
                function = found
                source = "\(id)/\(path)"
                inner.dataModule = module
                inner.assetsRoot = module.folder
            } else {
                guard let found = planner.wrappfile.function(named: name) else {
                    throw PlanError(description: "\(origin): no function \(name)")
                }
                function = found
                source = "Wrappfile"
                inner.dataModule = scope.dataModule
            }
            for option in instruction.options {
                inner.values[option.name] = try option.value.map { word throws(PlanError) in try substitute(word, in: scope, origin: origin) } ?? ""
            }
            // A bundle function's ARGs are its parameters too: mark it a function.
            if inner.dataModule == nil { inner.dataModule = ModuleFolder.none }
            try expand(function.body, scope: &inner, origin: "\(source) from \(origin)", into: &steps)
        }

        /// `origin` with `line` after its file: `nancy-drew/functions/patch:30
        /// from Wrappfile:16`.
        static func locate(_ origin: String, line: Int) -> String {
            guard let from = origin.range(of: " from ") else { return "\(origin):\(line)" }
            return "\(origin[..<from.lowerBound]):\(line)\(origin[from.lowerBound...])"
        }

        // MARK: - Values

        func holds(_ condition: Condition, scope: Scope, origin: String) throws(PlanError) -> Bool {
            let name = try substitute(Word(raw: condition.name, parts: (try? WrappfileParser.parts(of: condition.name, line: 0)) ?? []),
                                      in: scope, origin: origin)
            let actual: String?
            var list: [String]?
            switch condition.name {
            case "arch": actual = conditions.arch
            case "macos": actual = String(conditions.macos)
            case "updates":
                list = conditions.updates
                actual = conditions.updates.isEmpty ? nil : conditions.updates.joined(separator: ",")
            default:
                if condition.name.hasPrefix("previous.") {
                    let key = String(condition.name.dropFirst("previous.".count))
                    if key == "skipped" { list = conditions.previous["skipped"]?.split(separator: ",").map(String.init) ?? [] }
                    actual = conditions.previous[key]
                } else if condition.name.contains("${") {
                    actual = name
                } else {
                    actual = scope.values[condition.name] ?? conditions.choices[condition.name]
                }
            }
            guard let comparison = condition.comparison, let expected = condition.value else {
                return actual != nil && actual != ""
            }
            if comparison == .has { return (list ?? []).contains(expected) }
            guard let actual else { return comparison == .notEquals }
            switch comparison {
            case .equals: return actual == expected
            case .notEquals: return actual != expected
            case .atLeast: return actual.compare(expected, options: .numeric) != .orderedAscending
            case .atMost: return actual.compare(expected, options: .numeric) != .orderedDescending
            case .greater: return actual.compare(expected, options: .numeric) == .orderedDescending
            case .less: return actual.compare(expected, options: .numeric) == .orderedAscending
            case .has: return false
            }
        }

        func substitute(_ word: Word, in scope: Scope, origin: String) throws(PlanError) -> String {
            var result = ""
            for part in word.parts {
                switch part {
                case .text(let text): result += text
                case .substitution(let expression): result += try value(of: expression, in: scope, origin: origin)
                }
            }
            return result
        }

        func value(of expression: String, in scope: Scope, origin: String) throws(PlanError) -> String {
            // Nested substitutions first: data.patches.${id}.url
            let resolved: String
            if expression.contains("${") {
                let parts = (try? WrappfileParser.parts(of: expression, line: 0)) ?? []
                resolved = try substitute(Word(raw: expression, parts: parts), in: scope, origin: origin)
            } else {
                resolved = expression
            }
            if resolved.hasPrefix("assets/") {
                // A bundle file (or, in a module's function, the module's),
                // mounted for the step: the executor picks where.
                let root = scope.assetsRoot ?? planner.bundle.folder
                return "asset:" + root.appendingPathComponent(resolved).path
            }
            if resolved.hasPrefix("inputs.") {
                let parts = resolved.split(separator: ".").map(String.init)
                guard parts.count == 3, let input = edition.inputs?.first(where: { $0.id == parts[1] }) else {
                    throw PlanError(description: "\(origin): ${\(resolved)}: no such input")
                }
                let fields: [String: String?] = ["id": input.id, "format": input.format, "app-id": input.appId.map(String.init),
                                                 "common-folder": input.commonFolder, "exe": input.exe]
                guard let value = fields[parts[2]] ?? nil else {
                    throw PlanError(description: "\(origin): ${\(resolved)}: input \(parts[1]) has no \(parts[2])")
                }
                return value
            }
            if resolved.hasPrefix("data.") {
                return try dataValue(resolved, in: scope, origin: origin)
            }
            // name, name:-default, name:dir, name:file
            var name = resolved
            var fallback: String?
            var part: String?
            if let range = resolved.range(of: ":-") {
                name = String(resolved[..<range.lowerBound])
                fallback = String(resolved[range.upperBound...])
            } else if let colon = resolved.lastIndex(of: ":"), ["dir", "file"].contains(String(resolved[resolved.index(after: colon)...])) {
                name = String(resolved[..<colon])
                part = String(resolved[resolved.index(after: colon)...])
            }
            guard let value = scope.values[name], !value.isEmpty || fallback == nil else {
                if let fallback { return fallback }
                throw PlanError(description: "\(origin): ${\(resolved)}: nothing called \(name) is brought in")
            }
            switch part {
            case "dir": return (value as NSString).deletingLastPathComponent
            case "file": return (value as NSString).lastPathComponent
            default: return value
            }
        }

        /// `data.<table>.<key>.<field>…` in the function's module: a table's
        /// key is a property of an object, or the `id` of an item in a list
        /// (a table that is one list under a single key, as `patches.json`'s
        /// `patches`, is looked up by its items' ids).
        func dataValue(_ expression: String, in scope: Scope, origin: String) throws(PlanError) -> String {
            let fallback: String?
            var path = expression
            if let range = expression.range(of: ":-") {
                fallback = String(expression[range.upperBound...])
                path = String(expression[..<range.lowerBound])
            } else {
                fallback = nil
            }
            let parts = path.split(separator: ".").map(String.init).dropFirst()
            guard let module = scope.dataModule, module.manifest.id != ModuleFolder.none.manifest.id, let table = parts.first,
                  let file = module.manifest.data?.first(where: { ($0 as NSString).deletingPathExtension == table }),
                  var node = try? ModuleLoader.table(file, of: module) else {
                throw PlanError(description: "\(origin): ${\(expression)}: no data table \(parts.first ?? "")")
            }
            for key in parts.dropFirst() {
                guard let next = Self.lookup(key, in: node) else {
                    if let fallback { return fallback }
                    throw PlanError(description: "\(origin): ${\(expression)}: \(table) has no \(key)")
                }
                node = next
            }
            switch node {
            case let text as String: return text
            case let flag as Bool: return flag ? "true" : "false"
            case let number as Int: return String(number)
            case let number as Double: return String(number)
            default:
                if let fallback { return fallback }
                throw PlanError(description: "\(origin): ${\(expression)} isn't a value")
            }
        }

        static func lookup(_ key: String, in node: Any) -> Any? {
            if let object = node as? [String: Any] {
                if let value = object[key] { return value }
                let lists = object.values.compactMap { $0 as? [Any] }
                if lists.count == 1 { return lookup(key, in: lists[0]) }
                return nil
            }
            if let list = node as? [Any] {
                return list.first { ($0 as? [String: Any])?["id"] as? String == key }
            }
            return nil
        }
    }
}

nonisolated extension ModuleFolder {
    /// Marks a bundle's own function's scope, which has no module data.
    static let none = ModuleFolder(folder: URL(fileURLWithPath: "/"), manifest: ModuleManifest(
        format: 1, id: "", release: 1, native: nil, versions: [], dependsOn: nil, data: nil, assets: nil, functions: nil, assemble: nil))
}
