//
//  WrappfileChecker.swift
//  WrappBuilder
//
//  Whether a Wrappfile makes sense for its bundle and the modules there are.

import Foundation
import WrappModules

/// Checks a bundle's Wrappfile against its manifest and the modules, before
/// anything is built: every instruction is one a stage has (the core's, or
/// a module it `USE`s, is built `FROM`, or that depends on), with options it
/// takes; every `${…}` names something there is; every stage, function,
/// input and asset named exists; and the manifest's targets name stages.
public nonisolated struct WrappfileChecker {
    let manifest: Manifest
    let bundleFolder: URL
    let modules: [String: ModuleFolder]

    public init(manifest: Manifest, bundleFolder: URL, modules: [ModuleFolder]) {
        self.manifest = manifest
        self.bundleFolder = bundleFolder
        self.modules = Dictionary(modules.map { ($0.manifest.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// What a stage knows at a point: its modules, by the name it knows
    /// each by, and the ARGs it has brought in.
    struct Scope {
        var aliases: [String: String] = [:]
        var args: Set<String> = []
    }

    public func problems(_ file: Wrappfile) -> [String] {
        var problems: [String] = []
        var scopes: [String: Scope] = [:]
        let globals = Set(file.globalArgs.map(\.name))
        for duplicate in Self.duplicates(file.stages.compactMap(\.name)) {
            problems.append("two stages are called \(duplicate)")
        }
        for duplicate in Self.duplicates(file.functions.map(\.name)) {
            problems.append("two functions are called \(duplicate)")
        }
        for function in file.functions {
            var scope = Scope(aliases: allModuleAliases, args: Set(function.parameters.map(\.name)))
            check(function.body, in: &scope, file: file, inFunction: true, problems: &problems)
        }
        for stage in file.stages {
            var scope = Scope()
            switch stage.from {
            case .scratch:
                break
            case .stage(let name) where name == "base" || name == "previous":
                // Supplied by Second Chance: the edition's base stage, or the old wrapp.
                break
            case .stage(let name):
                if let inherited = scopes[name] {
                    scope.aliases = inherited.aliases
                } else {
                    problems.append("line \(stage.line): FROM \(name), but no stage before it is called that")
                }
            case .module(let id, let constraint, let stageName):
                if let module = modules[id] {
                    if !(BuildModules.native(module.manifest.native ?? "")?.stages ?? []).contains(stageName) {
                        problems.append("line \(stage.line): the \(id) module has no stage called \(stageName)")
                    }
                    if let constraint, !Self.satisfies(module, constraint) {
                        problems.append("line \(stage.line): no version of \(id) is \(constraint)")
                    }
                    addModule(id, as: nil, to: &scope)
                } else {
                    problems.append("line \(stage.line): FROM \(id)/\(stageName), but there's no \(id) module")
                }
            }
            check(stage.body, in: &scope, file: file, globals: globals, problems: &problems)
            if let name = stage.name { scopes[name] = scope }
        }
        problems += manifestProblems(file)
        return problems
    }

    // MARK: - Steps

    func check(_ steps: [Step], in scope: inout Scope, file: Wrappfile, globals: Set<String> = [],
               inFunction: Bool = false, problems: inout [String]) {
        for step in steps {
            switch step {
            case .instruction(let instruction):
                check(instruction, in: &scope, file: file, globals: globals, inFunction: inFunction, problems: &problems)
            case .conditional(let branches):
                // A branch's USEs and ARGs reach no further than it.
                for branch in branches {
                    var inner = scope
                    check(branch.steps, in: &inner, file: file, globals: globals, inFunction: inFunction, problems: &problems)
                }
            case .layer(let steps, _):
                check(steps, in: &scope, file: file, globals: globals, inFunction: inFunction, problems: &problems)
            }
        }
    }

    func check(_ instruction: Instruction, in scope: inout Scope, file: Wrappfile, globals: Set<String>,
               inFunction: Bool, problems: inout [String]) {
        let at = "line \(instruction.line): \(instruction.keyword)"
        let spec: InstructionSpec
        switch instruction.keyword {
        case "ARG":
            let declaration = WrappfileParser.argDeclaration(instruction.arguments.first ?? Word(raw: "", parts: []), line: instruction.line)
            if !inFunction, declaration.value != nil {
                problems.append("\(at) \(declaration.name) can't be given a value in a stage: give it one before the first FROM")
            } else if !inFunction, !globals.contains(declaration.name), !isChoice(declaration.name) {
                problems.append("\(at) \(declaration.name), but there's no global ARG or choice called that")
            }
            scope.args.insert(declaration.name)
            return
        case "USE":
            let words = instruction.arguments.map(\.raw)
            guard words.count == 1 || (words.count == 3 && words[1] == "AS") else {
                problems.append("\(at) is USE <module>[@<constraint>] [AS <name>]")
                return
            }
            let (id, constraint) = Self.splitConstraint(words[0])
            guard let module = modules[id] else {
                problems.append("\(at) \(id), but there's no \(id) module")
                return
            }
            if let constraint, !Self.satisfies(module, constraint) {
                problems.append("\(at) \(words[0]): no version of \(id) is \(constraint)")
            }
            let alias = words.count == 3 ? words[2] : nil
            if let alias, let other = scope.aliases[alias], other != id {
                problems.append("\(at) \(id) AS \(alias), but \(alias) is \(other) already")
            }
            addModule(id, as: alias, to: &scope)
            return
        case "DO":
            checkDo(instruction, scope: scope, file: file, problems: &problems)
            checkSubstitutions(instruction, scope: scope, inFunction: inFunction, problems: &problems)
            return
        default:
            if let alias = instruction.moduleAlias {
                guard let id = scope.aliases[alias] else {
                    problems.append("\(at): the stage doesn't USE a module called \(alias)")
                    return
                }
                guard let found = BuildModules.native(modules[id]?.manifest.native ?? "")?.instructions
                    .first(where: { $0.name == instruction.name }) else {
                    problems.append("\(at): the \(id) module has no instruction called \(instruction.name)")
                    return
                }
                spec = found
            } else if let found = InstructionSpec.core[instruction.keyword] {
                spec = found
            } else {
                problems.append("\(at) isn't an instruction")
                return
            }
        }
        checkOptions(instruction, spec: spec, problems: &problems)
        checkSubstitutions(instruction, scope: scope, inFunction: inFunction, problems: &problems)
        if spec.firstArgumentIsInput, let input = instruction.arguments.first?.raw, !inputIDs.contains(input) {
            problems.append("\(at) \(input), but no edition has an input called that")
        }
        if instruction.keyword == "COPY", let from = instruction.option("from")?.value?.raw,
           file.stage(named: from) == nil, !inputIDs.contains(from), from != "previous", from != "base" {
            problems.append("\(at) --from=\(from), but there's no stage or input called that")
        }
        if instruction.moduleAlias != nil, let from = instruction.option("from")?.value?.raw, !inputIDs.contains(from) {
            problems.append("\(at) --from=\(from), but no edition has an input called that")
        }
    }

    func checkOptions(_ instruction: Instruction, spec: InstructionSpec, problems: inout [String]) {
        let at = "line \(instruction.line): \(instruction.keyword)"
        let allowed = spec.options.merging(InstructionSpec.everyStep) { first, _ in first }
        var seen: Set<String> = []
        for option in instruction.options {
            guard let kind = allowed[option.name] else {
                problems.append("\(at) takes no --\(option.name)")
                continue
            }
            switch kind {
            case .flag where option.value != nil:
                problems.append("\(at) --\(option.name) takes no value")
            case .value where option.value == nil, .repeated where option.value == nil:
                problems.append("\(at) --\(option.name) needs a value")
            default:
                break
            }
            if kind != .repeated, !seen.insert(option.name).inserted {
                problems.append("\(at) has --\(option.name) twice")
            }
            if option.name == "mount" {
                let type = option.fields["type"] ?? ""
                if !InstructionSpec.mountTypes.contains(type) {
                    problems.append("\(at) --mount type=\(type) isn't a mount type (\(InstructionSpec.mountTypes.sorted().joined(separator: ", ")))")
                }
            }
        }
        for name in spec.required where instruction.option(name) == nil {
            problems.append("\(at) needs --\(name)")
        }
        if !spec.arguments.contains(instruction.arguments.count) {
            problems.append("\(at) takes \(Self.describe(spec.arguments)), not \(instruction.arguments.count)")
        }
    }

    func checkDo(_ instruction: Instruction, scope: Scope, file: Wrappfile, problems: inout [String]) {
        let at = "line \(instruction.line): DO"
        guard instruction.arguments.count == 1, let name = instruction.arguments.first?.raw else {
            problems.append("\(at) takes the function's name, then its parameters as --name=value")
            return
        }
        let parameters: [ArgDeclaration]
        if let dot = name.firstIndex(of: ".") {
            let alias = String(name[..<dot])
            let functionName = String(name[name.index(after: dot)...])
            guard let id = scope.aliases[alias], let module = modules[id] else {
                problems.append("\(at) \(name): the stage doesn't USE a module called \(alias)")
                return
            }
            guard let function = moduleFunction(functionName, of: module) else {
                problems.append("\(at) \(name): the \(id) module has no function called \(functionName)")
                return
            }
            parameters = function.parameters
        } else {
            guard let function = file.function(named: name) else {
                problems.append("\(at) \(name), but there's no function called that")
                return
            }
            parameters = function.parameters
        }
        let names = Set(parameters.map(\.name))
        for option in instruction.options where option.name != "name" && !names.contains(option.name) {
            problems.append("\(at) \(name) takes no --\(option.name)")
        }
        for parameter in parameters where parameter.value == nil && instruction.option(parameter.name) == nil {
            problems.append("\(at) \(name) needs --\(parameter.name)")
        }
    }

    func checkSubstitutions(_ instruction: Instruction, scope: Scope, inFunction: Bool, problems: inout [String]) {
        let words = instruction.arguments + instruction.options.compactMap(\.value)
        for substitution in words.flatMap(\.substitutions) {
            let at = "line \(instruction.line): ${\(substitution)}"
            if substitution.hasPrefix("assets/") {
                if !inFunction, !FileManager.default.fileExists(atPath: bundleFolder.appendingPathComponent(substitution).path) {
                    problems.append("\(at): the bundle has no \(substitution)")
                }
            } else if substitution.hasPrefix("inputs.") {
                let id = substitution.split(separator: ".").dropFirst().first.map(String.init) ?? ""
                if !inputIDs.contains(id) { problems.append("\(at): no edition has an input called \(id)") }
            } else if substitution.hasPrefix("data.") {
                if !inFunction { problems.append("\(at): only a module's function reads its data") }
            } else {
                let name = substitution.split(separator: ":", maxSplits: 1).first.map(String.init) ?? substitution
                let hasDefault = substitution.contains(":-")
                if !scope.args.contains(name), !hasDefault {
                    problems.append("\(at): nothing called \(name) is brought into the stage (ARG \(name))")
                }
            }
        }
    }

    // MARK: - The manifest

    func manifestProblems(_ file: Wrappfile) -> [String] {
        var problems: [String] = []
        let builds = manifest.editions.compactMap { edition in edition.build.map { ("edition \(edition.id)", $0) } }
            + (manifest.variants ?? []).compactMap { variant in variant.build.map { ("variant \(variant.id)", $0) } }
        for (owner, build) in builds {
            for stage in [build.target] + (build.base.map { [$0] } ?? []) where file.stage(named: stage) == nil {
                problems.append("manifest.yaml's \(owner) builds \(stage), which the Wrappfile has no stage called")
            }
        }
        if let setup = manifest.setup, file.function(named: setup) == nil {
            problems.append("manifest.yaml's setup is \(setup), which the Wrappfile has no function called")
        }
        return problems
    }

    // MARK: - Helpers

    var inputIDs: Set<String> { Set(manifest.editions.flatMap { $0.inputs?.map(\.id) ?? [] }) }

    /// Every module by its own name: what a function, which runs in its
    /// caller's stage, may name.
    var allModuleAliases: [String: String] {
        Dictionary(modules.keys.map { (Self.ownName($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    func isChoice(_ name: String) -> Bool {
        manifest.editions.contains { $0.choices?.keys.contains(Self.camelCase(name)) == true }
    }

    func addModule(_ id: String, as alias: String?, to scope: inout Scope) {
        scope.aliases[alias ?? Self.ownName(id)] = id
        for dependency in modules[id]?.manifest.dependsOn ?? [] {
            let dependencyID = Self.splitConstraint(dependency).id
            if !scope.aliases.values.contains(dependencyID) { addModule(dependencyID, as: nil, to: &scope) }
        }
    }

    func moduleFunction(_ name: String, of module: ModuleFolder) -> WrappfileFunction? {
        for path in module.manifest.functions ?? [] where (path as NSString).lastPathComponent == name {
            guard let text = try? String(contentsOf: module.file(path), encoding: .utf8),
                  let file = try? WrappfileParser.parse(text) else { return nil }
            return file.function(named: name)
        }
        return nil
    }

    static func ownName(_ id: String) -> String { String(id.split(separator: "/").last ?? Substring(id)) }

    static func splitConstraint(_ text: String) -> (id: String, constraint: String?) {
        guard let at = text.firstIndex(of: "@") else { return (text, nil) }
        return (String(text[..<at]), String(text[text.index(after: at)...]))
    }

    /// Whether one of the module's versions is `constraint`: exact, a prefix
    /// at a part boundary (`10` is any 10.x), or `>=`, `<=`, `>`, `<` one.
    static func satisfies(_ module: ModuleFolder, _ constraint: String) -> Bool {
        module.manifest.versions.contains { matches($0.version, constraint) }
    }

    static func matches(_ version: String, _ constraint: String) -> Bool {
        for op in [">=", "<=", ">", "<"] where constraint.hasPrefix(op) {
            let bound = String(constraint.dropFirst(op.count))
            let order = compare(version, bound)
            switch op {
            case ">=": return order != .orderedAscending
            case "<=": return order != .orderedDescending
            case ">": return order == .orderedDescending
            default: return order == .orderedAscending
            }
        }
        return version == constraint || version.hasPrefix(constraint + ".") || version.hasPrefix(constraint + "_")
    }

    /// Versions compared part by part, numbers as numbers (`10.0_8` < `10.0_10`).
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    static func camelCase(_ kebab: String) -> String {
        let parts = kebab.split(separator: "-")
        return (parts.first.map(String.init) ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// `launchMode` as `launch-mode`: a choice's name as written, from its
    /// decoded key.
    static func kebabCase(_ camel: String) -> String {
        camel.reduce(into: "") { result, character in
            if character.isUppercase { result += "-" + character.lowercased() } else { result.append(character) }
        }
    }

    static func duplicates(_ names: [String]) -> [String] {
        Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    }

    static func describe(_ range: ClosedRange<Int>) -> String {
        if range.lowerBound == range.upperBound { return "\(range.lowerBound) argument\(range.lowerBound == 1 ? "" : "s")" }
        if range.upperBound == Int.max { return "at least \(range.lowerBound) argument\(range.lowerBound == 1 ? "" : "s")" }
        return "\(range.lowerBound) to \(range.upperBound) arguments"
    }
}
