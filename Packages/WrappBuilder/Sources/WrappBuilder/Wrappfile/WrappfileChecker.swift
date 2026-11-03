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
/// takes; every path is one a module of the stage handles; every `${…}`
/// names something there is; every stage, function, input and asset named
/// exists; and the manifest's targets name stages. What can only be told
/// once a build is planned (a function's paths, in the stage that calls it)
/// the planner checks.
public nonisolated struct WrappfileChecker {
    let manifest: Manifest
    let bundleFolder: URL
    let modules: [String: ModuleFolder]
    let pathTypes: PathTypeRegistry
    let native: @Sendable (String) -> (any BuildModule.Type)?

    /// `pathTypes` and `native` are the shipped modules' unless a test gives
    /// its own.
    public init(manifest: Manifest, bundleFolder: URL, modules: [ModuleFolder],
                pathTypes: PathTypeRegistry = .shipped,
                native: @escaping @Sendable (String) -> (any BuildModule.Type)? = BuildModules.native) {
        self.manifest = manifest
        self.bundleFolder = bundleFolder
        self.modules = Dictionary(modules.map { ($0.manifest.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        self.pathTypes = pathTypes
        self.native = native
    }

    /// What a stage knows at a point: its modules, by the name it knows
    /// each by (in lower case), and the values declared, innermost last.
    struct Scope {
        var aliases: [String: String] = [:]
        var frames: [[String: Declared]] = [[:]]
        /// In a function, which runs in whichever stage calls it: its paths
        /// are checked when it's planned.
        var inFunction = false
        /// Past a function's top, where its INPUTs are.
        var pastTop = false

        var moduleIDs: Set<ModuleID> { Set(aliases.values.map(ModuleID.init(rawValue:))) }

        func declared(_ name: String) -> Declared? {
            for frame in frames.reversed() {
                if let found = frame[name] { return found }
            }
            return nil
        }
    }

    /// A name a declaration made, and whether anything reads it.
    final class Declared {
        let kind: Declaration.Kind
        let line: Int
        var used = false
        init(_ kind: Declaration.Kind, line: Int) {
            self.kind = kind
            self.line = line
        }
    }

    /// What the checker finds: errors, which stop a bundle loading, and
    /// warnings, which `sc bundle check` shows.
    public struct Findings {
        public var errors: [String] = []
        public var warnings: [String] = []
    }

    public func problems(_ file: Wrappfile) -> [String] { findings(file).errors }

    public func warnings(_ file: Wrappfile) -> [String] { findings(file).warnings }

    public func findings(_ file: Wrappfile) -> Findings {
        var found = Findings()
        var scopes: [String: Scope] = [:]
        var all: [(name: String, declared: Declared)] = []
        var globals = Scope()
        for instruction in file.globals {
            check(instruction, in: &globals, file: file, scopes: [:], found: &found, all: &all)
        }
        for duplicate in Self.duplicates(file.stages.compactMap(\.name)) {
            found.errors.append("two stages are called \(duplicate)")
        }
        for duplicate in Self.duplicates(file.functions.map(\.name)) {
            found.errors.append("two functions are called \(duplicate)")
        }
        for function in file.functions {
            checkName(function.nameAsWritten ?? function.name, kind: "FUNCTION", line: function.line, found: &found)
            if modules[function.name] != nil {
                found.warnings.append("line \(function.line): FUNCTION \(function.name) is named like a module: DO \(function.name).… is this "
                    + "function's, and the module's functions are written DO module.\(function.name).<function>")
            }
            var scope = Scope(aliases: allModuleAliases, inFunction: true)
            check(function.body, in: &scope, file: file, scopes: scopes, found: &found, all: &all)
        }
        for stage in file.stages {
            if let name = stage.nameAsWritten ?? stage.name {
                checkName(name, kind: "stage", line: stage.line, found: &found)
            }
            var scope = globals
            scope.aliases = [:]
            scope.frames.append([:])
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
                    found.errors.append("line \(stage.line): FROM \(name), but no stage before it is called that")
                }
            case .module(let id, let constraint, let stageName):
                if let module = modules[id] {
                    let wrappfiles = (module.manifest.stages ?? []).map { ($0 as NSString).lastPathComponent }
                    if !(native(module.manifest.native ?? "")?.stages ?? []).contains(stageName), !wrappfiles.contains(stageName) {
                        found.errors.append("line \(stage.line): the \(id) module has no stage called \(stageName)")
                    }
                    if let constraint, !Self.satisfies(module, constraint) {
                        found.errors.append("line \(stage.line): no version of \(id) is \(constraint)")
                    }
                    addModule(id, as: nil, to: &scope)
                } else {
                    found.errors.append("line \(stage.line): FROM \(id)/\(stageName), but there's no \(id) module")
                }
            }
            check(stage.body, in: &scope, file: file, scopes: scopes, found: &found, all: &all)
            if let name = stage.name { scopes[name] = scope }
        }
        for (name, declared) in all where !declared.used {
            found.warnings.append("line \(declared.line): \(declared.kind.rawValue) \(name) is never read")
        }
        found.errors += manifestProblems(file)
        return found
    }

    /// A stage's or function's name, as Docker has a stage's: a letter,
    /// then letters, digits, `-`, `_` and `.`, in any case, but upper case
    /// is warned about, to keep names and instructions apart.
    func checkName(_ written: String, kind: String, line: Int, found: inout Findings) {
        let lowered = written.lowercased()
        if lowered.range(of: "^[a-z][a-z0-9-_.]*$", options: .regularExpression) == nil {
            found.errors.append("line \(line): \(kind) name \(written) must start with a letter and hold only letters, digits, -, _ and .")
        } else if lowered != written {
            found.warnings.append("line \(line): \(kind) name \(written) is written in upper case; names are case-insensitive, and written in lower case")
        }
    }

    // MARK: - Steps

    func check(_ steps: [Step], in scope: inout Scope, file: Wrappfile, scopes: [String: Scope], found: inout Findings,
               all: inout [(name: String, declared: Declared)]) {
        for step in steps {
            switch step {
            case .instruction(let instruction):
                check(instruction, in: &scope, file: file, scopes: scopes, found: &found, all: &all)
            case .conditional(let branches):
                scope.pastTop = true
                // A branch is a scope: its USEs and declarations reach no further than it.
                for branch in branches {
                    var inner = scope
                    inner.frames.append([:])
                    if let condition = branch.condition {
                        let at = "line \(branch.line): IF"
                        checkReferences([condition.left, condition.right], at: at, scope: inner, found: &found)
                    }
                    check(branch.steps, in: &inner, file: file, scopes: scopes, found: &found, all: &all)
                }
            case .layer(let steps, _):
                scope.pastTop = true
                check(steps, in: &scope, file: file, scopes: scopes, found: &found, all: &all)
            }
        }
    }

    func check(_ instruction: Instruction, in scope: inout Scope, file: Wrappfile, scopes: [String: Scope], found: inout Findings,
               all: inout [(name: String, declared: Declared)]) {
        let at = "line \(instruction.line): \(instruction.keyword)"
        let spec: InstructionSpec
        if let declaration = Declaration(instruction) {
            checkDeclaration(declaration, instruction, in: &scope, found: &found, all: &all)
            return
        }
        scope.pastTop = true
        switch instruction.keyword {
        case "USE":
            let words = instruction.arguments.map(\.raw)
            guard words.count == 1 || (words.count == 3 && words[1].uppercased() == "AS") else {
                found.errors.append("\(at) is USE <module>[@<constraint>] [AS <name>]")
                return
            }
            let (written, constraint) = Self.splitConstraint(words[0])
            let id = written.lowercased()
            guard let module = modules[id] else {
                found.errors.append("\(at) \(id), but there's no \(id) module")
                return
            }
            if let constraint, !Self.satisfies(module, constraint) {
                found.errors.append("\(at) \(words[0]): no version of \(id) is \(constraint)")
            }
            let alias = words.count == 3 ? words[2].lowercased() : nil
            if Reference.coreNamespaces.contains(alias ?? Self.ownName(id)) {
                found.warnings.append("\(at) \(words.joined(separator: " ")): \(alias ?? Self.ownName(id)) is a namespace of the core's, "
                    + "which always wins: this module is read as ${module.\(alias ?? Self.ownName(id)).…}")
            }
            if let alias, let other = scope.aliases[alias], other != id {
                found.errors.append("\(at) \(id) AS \(words[2]), but \(alias) is \(other) already")
            }
            let name = alias ?? Self.ownName(id)
            if InstructionSpec.core[name.uppercased()] != nil || InstructionSpec.blockWords.contains(name.uppercased()) || name == "do" {
                found.warnings.append("\(at) \(words.joined(separator: " ")): \(name) is a core instruction, which always wins: "
                    + "this module's instructions are written MODULE.\(name.uppercased()).<INSTRUCTION>")
            }
            addModule(id, as: alias, to: &scope)
            return
        case "DO":
            checkDo(instruction, scope: scope, file: file, found: &found)
            checkReferences(instruction.options.compactMap(\.value), at: at, scope: scope, found: &found)
            return
        default:
            if let alias = instruction.moduleAlias {
                let explicit = instruction.keyword.hasPrefix("MODULE.")
                if !explicit, InstructionSpec.core[alias.uppercased()] != nil {
                    found.errors.append("\(at) isn't an instruction: \(alias.uppercased()) is the core's; "
                        + "a module called \(alias) is reached as MODULE.\(instruction.keyword)")
                    return
                }
                guard let id = scope.aliases[alias] else {
                    found.errors.append("\(at): the stage doesn't USE a module called \(alias)")
                    return
                }
                guard let declared = native(modules[id]?.manifest.native ?? "")?.instructions
                    .first(where: { $0.name == instruction.name }) else {
                    found.errors.append("\(at): the \(id) module has no instruction called \(instruction.name)")
                    return
                }
                spec = declared
            } else if let core = InstructionSpec.core[instruction.keyword] {
                spec = core
            } else {
                found.errors.append("\(at) isn't an instruction")
                return
            }
        }
        checkOptions(instruction, spec: spec, scope: scope, found: &found)
        checkReferences(instruction.arguments + instruction.options.compactMap(\.value), at: at, scope: scope, found: &found)
        checkPaths(instruction, spec: spec, scope: scope, scopes: scopes, file: file, found: &found)
        if instruction.keyword == "ICON", let icon = instruction.arguments.first?.raw, !icon.contains("${"),
           !(icon.hasPrefix("/Resources/") && icon.hasSuffix(".icns")) {
            found.errors.append("\(at) \(icon): an app's icon is an .icns in its Resources/: /Resources/<name>.icns")
        }
        if instruction.keyword == "VOLUME", let name = instruction.arguments.first?.raw, !name.contains("${"),
           manifest.volumes?[name] == nil {
            found.errors.append("\(at) \(name), but manifest.yaml has no volume called that")
        }
        // A patcher isn't an install: it looks for no program afterwards.
        if spec.options["patch"] != nil, instruction.option("patch") != nil, instruction.option("creates") != nil {
            found.errors.append("\(at) --patch takes no --creates: a patcher is run in its folder, and nothing is looked for afterwards")
        }
        // An input is written as one, ${input.<name>}, wherever one is taken.
        var inputWords = instruction.arguments.enumerated().filter { spec.role(ofArgument: $0.offset) == .input }.map(\.element)
        inputWords += instruction.options.filter { spec.role(ofOption: $0.name) == .input }.compactMap(\.value)
        for word in inputWords where !Self.isWholeInput(word, scope: scope) {
            found.errors.append("\(at) \(word.raw): an input is written ${input.<name>}, naming an INPUT")
        }
        if instruction.keyword == "COPY", let from = instruction.option("from")?.value,
           !Self.isWholeInput(from, scope: scope), file.stage(named: from.raw) == nil, from.raw != "previous", from.raw != "base" {
            found.errors.append("\(at) --from=\(from.raw), but there's no stage called that (an input is written ${input.<name>})")
        }
    }

    /// Whether `word` is a whole input, `${input.<name>}`, of an INPUT in scope.
    static func isWholeInput(_ word: Word, scope: Scope) -> Bool {
        guard let reference = word.lone, reference.root == "input", reference.segments.count == 2,
              let name = reference.plainPath.first else { return false }
        return scope.declared(name)?.kind == .input
    }

    /// `INPUT`, `CONST`, `VAR` or `SET`: where it may be, and what it names.
    func checkDeclaration(_ declaration: Declaration, _ instruction: Instruction, in scope: inout Scope, found: inout Findings,
                          all: inout [(name: String, declared: Declared)]) {
        let at = "line \(instruction.line): \(declaration.kind.rawValue) \(declaration.name)"
        let isGlobal = scope.frames.count == 1 && !scope.inFunction
        if let value = declaration.value {
            checkReferences([value], at: at, scope: scope, found: &found)
        }
        for option in instruction.options where !["default", "secret"].contains(option.name) || declaration.kind != .input {
            found.errors.append("\(at) takes no --\(option.name)")
        }
        switch declaration.kind {
        case .input:
            if !(isGlobal || (scope.inFunction && !scope.pastTop && scope.frames.count == 1)) {
                found.errors.append("\(at): an INPUT is declared before the first FROM, or at a function's top")
                return
            }
        case .const:
            if scope.declared(declaration.name)?.kind == .const {
                found.errors.append("\(at): \(declaration.name) is a CONST already, which can't be declared again")
                return
            }
        case .variable:
            break
        case .set:
            switch scope.declared(declaration.name)?.kind {
            case .variable?: return
            case let kind?: found.errors.append("\(at): \(declaration.name) is a\(kind == .input ? "n" : "") \(kind.rawValue), which can't be set")
            case nil: found.errors.append("\(at), but there's no VAR called \(declaration.name)")
            }
            return
        }
        if !scope.inFunction { scope.pastTop = true }
        let declared = Declared(declaration.kind, line: instruction.line)
        scope.frames[scope.frames.count - 1][declaration.name] = declared
        all.append((declaration.name, declared))
    }

    func checkOptions(_ instruction: Instruction, spec: InstructionSpec, scope: Scope, found: inout Findings) {
        let at = "line \(instruction.line): \(instruction.keyword)"
        let allowed = spec.options.merging(InstructionSpec.everyStep) { first, _ in first }
        var seen: Set<String> = []
        for option in instruction.options {
            let kind: InstructionSpec.OptionKind
            if let dot = option.name.firstIndex(of: ".") {
                // A module's option on a core instruction: --<alias>.<option>.
                let alias = option.name[..<dot].lowercased()
                let name = String(option.name[option.name.index(after: dot)...])
                guard let id = scope.aliases[alias] else {
                    found.errors.append("\(at) --\(option.name): the stage doesn't USE a module called \(alias)")
                    continue
                }
                guard instruction.moduleAlias == nil,
                      let declared = native(modules[id]?.manifest.native ?? "")?.coreOptions[instruction.keyword]?[name] else {
                    found.errors.append("\(at) --\(option.name): the \(id) module adds no option \(name) to \(instruction.keyword)")
                    continue
                }
                kind = declared
            } else if let declared = allowed[option.name] {
                kind = declared
            } else {
                found.errors.append("\(at) takes no --\(option.name)")
                continue
            }
            switch kind {
            case .flag where option.value != nil:
                found.errors.append("\(at) --\(option.name) takes no value")
            case .value where option.value == nil, .repeated where option.value == nil:
                found.errors.append("\(at) --\(option.name) needs a value")
            default:
                break
            }
            if kind != .repeated, !seen.insert(option.name).inserted {
                found.errors.append("\(at) has --\(option.name) twice")
            }
            if option.name == "mount" {
                checkMount(option, at: at, scope: scope, found: &found)
            }
        }
        for name in spec.required where instruction.option(name) == nil {
            found.errors.append("\(at) needs --\(name)")
        }
        if !spec.arguments.contains(instruction.arguments.count) {
            found.errors.append("\(at) takes \(Self.describe(spec.arguments)), not \(instruction.arguments.count)")
        }
    }

    /// A `--mount=`'s type, and the fields modules add to it.
    func checkMount(_ option: InstructionOption, at: String, scope: Scope, found: inout Findings) {
        let fields = option.fields
        let type = fields["type"] ?? ""
        guard InstructionSpec.mountTypes.contains(type) else {
            found.errors.append("\(at) --mount type=\(type) isn't a mount type (\(InstructionSpec.mountTypes.sorted().joined(separator: ", ")))")
            return
        }
        for key in fields.keys.sorted() {
            guard let dot = key.firstIndex(of: ".") else { continue }
            let alias = key[..<dot].lowercased()
            let field = String(key[key.index(after: dot)...])
            guard let id = scope.aliases[alias] else {
                found.errors.append("\(at) --mount=…,\(key)=…: the stage doesn't USE a module called \(alias)")
                continue
            }
            if !(native(modules[id]?.manifest.native ?? "")?.mountFields[type]?.contains(field) ?? false) {
                found.errors.append("\(at) --mount=…,\(key)=…: the \(id) module adds no field \(field) to a \(type) mount")
            }
        }
    }

    // MARK: - Paths

    /// Each path is one a module of the stage handles, in the role it's in.
    /// A path a `${…}` starts can only be told once planned, and a
    /// function's runs in whichever stage calls it: the planner checks those.
    func checkPaths(_ instruction: Instruction, spec: InstructionSpec, scope: Scope, scopes: [String: Scope],
                    file: Wrappfile, found: inout Findings) {
        let at = "line \(instruction.line): \(instruction.keyword)"
        var copyFrom: Scope?
        if instruction.keyword == "COPY", let from = instruction.option("from")?.value?.raw {
            copyFrom = scopes[from.lowercased()]
        }
        func check(_ word: Word, _ role: InstructionSpec.Role) {
            let modules: Set<ModuleID>
            let pathRole: PathType.Role
            switch role {
            case .location: (modules, pathRole) = (scope.moduleIDs, .location)
            case .program: (modules, pathRole) = (scope.moduleIDs, .program)
            case .copySource where instruction.option("from") == nil:
                // A file of the bundle's.
                check(word, .file)
                return
            case .copySource:
                // In the stage it's copied from; a path in an input is the input's.
                guard let copyFrom else { return }
                (modules, pathRole) = (copyFrom.moduleIDs, .location)
            case .file:
                // A bundle's file, as a relative path, is there; a module's
                // function's are checked when it's planned.
                if !scope.inFunction, !word.raw.contains("${"), !word.raw.hasPrefix("module:"), !word.raw.hasPrefix("/") {
                    let relative = word.raw.hasPrefix("bundle:") ? String(word.raw.dropFirst("bundle:".count)) : word.raw
                    if !FileManager.default.fileExists(atPath: bundleFolder.appendingPathComponent(relative).path) {
                        found.errors.append("\(at) \(word.raw): the bundle has no \(relative)")
                    }
                }
                return
            case .input, .text: return
            }
            if let problem = pathProblem(word.raw, as: pathRole, modules: modules, inFunction: scope.inFunction) {
                found.errors.append("\(at) \(word.raw): \(problem)")
            }
        }
        for (index, argument) in instruction.arguments.enumerated() {
            check(argument, spec.role(ofArgument: index))
        }
        for option in instruction.options {
            guard let value = option.value else { continue }
            if option.name == "mount" {
                for (field, text) in option.fields {
                    if let role = InstructionSpec.mountFieldRoles[field] {
                        check(Word(raw: text, parts: (try? WrappfileParser.parts(of: text, line: 0)) ?? []), role)
                    }
                }
            } else {
                check(value, spec.role(ofOption: option.name))
            }
        }
    }

    /// What's wrong with `path` in `role`, in a stage with `modules`; nil
    /// for nothing, or for a path that can't be told yet.
    func pathProblem(_ path: String, as role: PathType.Role, modules: Set<ModuleID>, inFunction: Bool) -> String? {
        if path.hasPrefix("${") { return nil }
        if let (type, _) = pathTypes.split(path) {
            if !type.roles.contains(role) {
                return "a \(type.name): path isn't a \(role.rawValue)"
            }
            if !inFunction, !modules.contains(type.module) {
                return "\(type.name): paths are \(type.module)'s, which the stage doesn't USE"
            }
            return nil
        }
        if inFunction { return nil }
        guard let form = PathTypeRegistry.shortForm(of: path) else { return nil }
        if form == .folder, role == .location {
            // A bare path is in the app: `/` is its Contents/, `/../` its top level, and nothing higher.
            return Self.leavesTheApp(path) ? "it goes above the app's top level" : nil
        }
        let claiming = pathTypes.claiming(form, as: role, among: modules)
        switch claiming.count {
        case 1:
            return nil
        case 0:
            let uses = modules.map(\.rawValue).sorted().joined(separator: ", ")
            let what = form == .driveLetter ? "\(path.prefix(2)) paths" : "a folder as a \(role.rawValue)"
            return "no module of this stage handles \(what) (it uses \(uses.isEmpty ? "none" : uses))"
        default:
            let names = claiming.map(\.name)
            return "both \(names.joined(separator: " and ")) take \(path.prefix(2)) paths here; write \(names.map { "\($0):\(path.prefix(2))/…" }.joined(separator: " or "))"
        }
    }

    /// Whether a bare `/…` path's `..`s take it above the app's top level
    /// (`/` being its `Contents/`).
    static func leavesTheApp(_ path: String) -> Bool {
        var depth = 1  // Contents/ is one below the top.
        for part in path.split(separator: "/") {
            if part == ".." { depth -= 1 } else if part != "." { depth += 1 }
            if depth < 0 { return true }
        }
        return false
    }

    func checkDo(_ instruction: Instruction, scope: Scope, file: Wrappfile, found: inout Findings) {
        let at = "line \(instruction.line): DO"
        guard instruction.arguments.count == 1, let name = instruction.arguments.first?.raw else {
            found.errors.append("\(at) takes the function's name, then its parameters as --name=value")
            return
        }
        let parameters: [Declaration]
        if let dot = name.firstIndex(of: ".") {
            let alias = name[..<dot].lowercased()
            let functionName = name[name.index(after: dot)...].lowercased()
            guard let id = scope.aliases[alias], let module = modules[id] else {
                found.errors.append("\(at) \(name): the stage doesn't USE a module called \(alias)")
                return
            }
            guard let function = moduleFunction(functionName, of: module) else {
                found.errors.append("\(at) \(name): the \(id) module has no function called \(functionName)")
                return
            }
            parameters = function.parameters
        } else {
            guard let function = file.function(named: name) else {
                found.errors.append("\(at) \(name), but there's no function called that")
                return
            }
            parameters = function.parameters
        }
        let names = Set(parameters.map(\.name))
        for option in instruction.options where option.name != "name" && !names.contains(option.name) {
            found.errors.append("\(at) \(name) takes no --\(option.name)")
        }
        for parameter in parameters where parameter.value == nil && instruction.option(parameter.name) == nil {
            // The caller's input or constant of the same name gives it otherwise.
            if let caller = scope.declared(parameter.name), caller.kind == .input || caller.kind == .const {
                caller.used = true
                continue
            }
            found.errors.append("\(at) \(name) needs --\(parameter.name)")
        }
    }

    /// Every `${…}` in `words` names something there is: a declared
    /// `INPUT`, `CONST` or `VAR` (in any branch, reached or not), a field of
    /// the platform, or a module of the stage, its data checked against
    /// the table's schema.
    func checkReferences(_ words: [Word], at: String, scope: Scope, found: inout Findings) {
        for word in words {
            for expression in word.substitutions {
                guard let reference = try? Reference.parse(expression) else { continue }
                for each in reference.all {
                    if let problem = referenceProblem(each, scope: scope) {
                        found.errors.append("\(at) ${\(expression)}: \(problem)")
                    }
                }
            }
        }
    }

    func referenceProblem(_ reference: Reference, scope: Scope) -> String? {
        let path = reference.plainPath
        switch reference.root {
        case "input", "const", "var":
            guard let name = path.first else { return "name what it reads: ${\(reference.root).<name>}" }
            guard let declared = scope.declared(name) else {
                let kind = reference.root == "var" ? "VAR" : reference.root.uppercased()
                return "no \(kind) called \(name) here"
                    + (scope.inFunction && reference.root != "input" ? " (a function reads its caller's values only through its own INPUTs)" : "")
            }
            let expected: Declaration.Kind = reference.root == "input" ? .input : reference.root == "const" ? .const : .variable
            guard declared.kind == expected else {
                let namespace = declared.kind == .input ? "input" : declared.kind == .const ? "const" : "var"
                return "\(name) is a\(declared.kind == .input ? "n" : "") \(declared.kind.rawValue): read it as ${\(namespace).\(name)}"
            }
            declared.used = true
            return nil
        case "platform":
            return ["arch", "macos"].contains(path.first ?? "") && path.count == 1 ? nil : "the platform has arch and macos"
        case "program":
            return "program is only read by a signal, which nothing has yet"
        case "self":
            return "self is only in a module's own files"
        case "module":
            guard let name = path.first else { return "name the module: ${module.<name>.…}" }
            guard let id = scope.aliases[name.lowercased()] else { return "the stage has no module called \(name)" }
            return moduleReferenceProblem(id, Array(reference.segments.dropFirst(2)))
        case let root:
            guard let id = scope.aliases[root.lowercased()] else {
                return "\(root) is no namespace (input, const, var, platform, module, self), and no module of the stage"
            }
            return moduleReferenceProblem(id, Array(reference.segments.dropFirst()))
        }
    }

    /// A module's `version`, or a path into its data that its table's
    /// schema allows, as far as the schema can tell.
    func moduleReferenceProblem(_ id: String, _ segments: [Reference.Segment]) -> String? {
        guard case .name(let field)? = segments.first else { return "a module has version and data" }
        switch field {
        case "version":
            return segments.count == 1 ? nil : "a version is text, with nothing in it"
        case "data":
            guard case .name(let table)? = segments.dropFirst().first else { return "name a table: data.<table>" }
            guard let module = modules[id],
                  let file = module.manifest.data?.first(where: { ($0 as NSString).deletingPathExtension == table }) else {
                return "the \(id) module has no data table \(table)"
            }
            let schemaURL = module.file((file as NSString).deletingPathExtension + ".schema.json")
            guard let data = try? Data(contentsOf: schemaURL),
                  let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return SchemaPath.problem(Array(segments.dropFirst(2)), schema: schema, table: table)
        default:
            return "a module has version and data, not \(field)"
        }
    }

    // MARK: - The manifest

    func manifestProblems(_ file: Wrappfile) -> [String] {
        var problems: [String] = []
        let builds = manifest.editions.compactMap { edition in edition.build.map { ("edition \(edition.id)", $0) } }
        for (owner, build) in builds {
            for stage in [build.target, build.base].compactMap({ $0 }) where file.stage(named: stage) == nil {
                problems.append("manifest.yaml's \(owner) builds \(stage), which the Wrappfile has no stage called")
            }
        }
        if let setup = manifest.setup, file.function(named: setup) == nil {
            problems.append("manifest.yaml's setup is \(setup), which the Wrappfile has no function called")
        }
        return problems
    }

    // MARK: - Helpers

    /// Every module by its own name: what a function, which runs in its
    /// caller's stage, may name.
    var allModuleAliases: [String: String] {
        Dictionary(modules.keys.map { (Self.ownName($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    func addModule(_ id: String, as alias: String?, to scope: inout Scope) {
        scope.aliases[(alias ?? Self.ownName(id)).lowercased()] = id
        for dependency in modules[id]?.manifest.dependsOn ?? [] {
            let dependencyID = Self.splitConstraint(dependency).id.lowercased()
            if !scope.aliases.values.contains(dependencyID) { addModule(dependencyID, as: nil, to: &scope) }
        }
    }

    func moduleFunction(_ name: String, of module: ModuleFolder) -> WrappfileFunction? {
        for path in module.manifest.functions ?? [] where (path as NSString).lastPathComponent.lowercased() == name.lowercased() {
            guard let text = try? String(contentsOf: module.file(path), encoding: .utf8),
                  let file = try? WrappfileParser.parse(text) else { return nil }
            return file.function(named: name)
        }
        return nil
    }

    static func ownName(_ id: String) -> String { String(id.split(separator: "/").last ?? Substring(id)).lowercased() }

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

/// A path into a data table, against the table's JSON Schema: each name a
/// property the schema has, through `$ref`s, items and a table that is one
/// list (looked up by `id`), as far as the schema says.
nonisolated enum SchemaPath {
    static func problem(_ segments: [Reference.Segment], schema root: [String: Any], table: String) -> String? {
        var node: [String: Any]? = resolve(root, root: root)
        var walked = table
        for segment in segments {
            guard let current = node else { return nil }
            let name: String?
            if case .name(let text) = segment { name = text } else { name = nil }
            let properties = current["properties"] as? [String: Any] ?? [:]
            if let name, let property = properties[name] as? [String: Any] {
                node = resolve(property, root: root)
                walked += ".\(name)"
                continue
            }
            // A list's item, or a table that is one list under a single key, by its id.
            if let items = current["items"] as? [String: Any] {
                node = resolve(items, root: root)
                continue
            }
            let lists = properties.values.compactMap { ($0 as? [String: Any]).map { resolve($0, root: root) } }.filter { $0["items"] != nil }
            if lists.count == 1, let items = lists[0]["items"] as? [String: Any] {
                node = resolve(items, root: root)
                continue
            }
            if let additional = current["additionalProperties"] as? [String: Any] {
                node = resolve(additional, root: root)
                continue
            }
            if let name, current["properties"] != nil, current["additionalProperties"] as? Bool == false {
                return "\(walked) has no \(name)"
            }
            return nil
        }
        return nil
    }

    static func resolve(_ schema: [String: Any], root: [String: Any]) -> [String: Any] {
        guard let ref = schema["$ref"] as? String, ref.hasPrefix("#/$defs/"),
              let defs = root["$defs"] as? [String: Any],
              let target = defs[String(ref.dropFirst("#/$defs/".count))] as? [String: Any] else { return schema }
        return resolve(target, root: root)
    }
}
