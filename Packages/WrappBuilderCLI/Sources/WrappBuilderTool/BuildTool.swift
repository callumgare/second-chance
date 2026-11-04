import Foundation
import NancyDrewExecutor
import WineExecutor
import WrappBuilder

/// `wrapp-builder build`: a bundle's stage built into an app, by the runner,
/// with the executors the tool has. It speaks only the builder's language: a
/// target, inputs by name, the app's id, the template to lay in.
public nonisolated enum BuildTool {
    public struct Request: Sendable {
        public var bundle: URL
        public var modules: URL
        public var edition: String?
        public var target: String?
        public var inputs: [String: URL]
        public var appID: String?
        public var template: URL?
        public var output: URL
        public var allowPaths: [String]
        public var json: Bool
    }

    /// The executors this tool runs, by module: each shipped module's that
    /// has moved into its package. The wine module's lays in the helpers the
    /// template carries, when it's given one, and gives winetricks the
    /// engine's build tools.
    static func executors(template: URL?) -> [String: any ModuleExecutor] {
        let helpers = template?.appendingPathComponent("Contents/Frameworks/in_process_helpers.dylib")
        return [
            "wine": WineExecutor(helpers: helpers, buildTools: { tree in
                guard let wine = EngineInstall.installed(in: tree.appendingPathComponent("Contents")).first(where: { $0.module == "wine" })
                else { return nil }
                return EngineStore.standardRoot().appendingPathComponent("\(wine.hash)/\(EngineTree.buildTools)")
            }),
            "nancy-drew": NancyDrewExecutor(),
        ]
    }

    public static func build(_ request: Request, output: some ToolOutput) async throws {
        let modules = try ModuleTool.loadAll(root: request.modules, output: output)
        let plan = try WrappfileTool.planned(bundle: request.bundle, modules: modules, edition: request.edition, target: request.target,
                                             conditions: .thisMac, allowPaths: request.allowPaths, output: output)
        let executors = Self.executors(template: request.template)
        let missing = Set(plan.stages.flatMap(\.steps).compactMap(\.module)).subtracting(executors.keys).sorted()
        guard missing.isEmpty else {
            throw ToolError("this tool can't run the \(missing.joined(separator: ", ")) \(missing.count == 1 ? "module's" : "modules'") instructions yet")
        }
        let id: String
        do {
            id = try plan.app.id(given: request.appID)
        } catch {
            throw ToolError(error.description)
        }
        let files = FileManager.default
        guard !files.fileExists(atPath: request.output.path) else { throw ToolError("\(request.output.path) already exists.") }
        // Each stage's tree in a working folder of the build's own.
        let folder = files.temporaryDirectory.appendingPathComponent("wrapp-builder-\(UUID().uuidString)")
        defer { try? files.removeItem(at: folder) }
        let store = EngineStore(root: EngineStore.standardRoot(), preparer: EnginePreparer(downloader: .forTool()))
        let printer = EventPrinter(json: request.json)
        let emitter = OrderedEmitter { event in printer.print(event) }
        let downloader = Downloader.forTool()
        let configuration = RunnerConfiguration(
            executors: executors, inputs: GivenInputs(request.inputs), emitter: emitter,
            ask: { question in try TerminalQuestions.ask(question) },
            fetch: { url, sha256, progress in
                try await downloader.fetch(DownloadRequest(urls: [url], sha256: sha256), progress: progress).file
            },
            engine: { id, version in
                guard let module = modules.first(where: { $0.manifest.id == id }) else { throw ToolError("there's no \(id) module") }
                return try await store.engine(module, version: version) { step in output.line(step) }
            },
            moduleFolders: Dictionary(uniqueKeysWithValues: modules.map { ($0.manifest.id, $0.folder) }))
        let tree: URL
        do {
            tree = try await PlanRunner(plan: plan, configuration: configuration).build(in: folder)
        } catch let error as StepFailure {
            await emitter.finish()
            throw ToolError(error.description)
        } catch {
            await emitter.finish()
            throw error
        }
        await emitter.finish()
        if let template = request.template {
            do {
                try WrappAssembler.layIn(template, into: tree)
            } catch let problem as WrappAssembler.Problem {
                throw ToolError(problem.description)
            }
        }
        try setBundleID(id, in: tree)
        try files.moveItem(at: tree, to: request.output)
        if request.template == nil {
            output.info("Built \(request.output.path) with no template laid in: it holds what the steps made, and isn't an app that runs.")
        }
        output.success("Built \(request.output.path) (\(id)).")
    }

    /// The app's id in its `Info.plist`, making one if the tree has none.
    static func setBundleID(_ id: String, in tree: URL) throws {
        let file = tree.appendingPathComponent("Contents/Info.plist")
        var plist: [String: Any] = [:]
        if let data = try? Data(contentsOf: file),
           let read = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            plist = read
        }
        plist["CFBundleIdentifier"] = id
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file)
    }
}

/// A build's events on stdout: a line each, or a JSON object each with
/// `--events=json`. `EMIT` strings are printed as they are, unread.
nonisolated struct EventPrinter: Sendable {
    let json: Bool

    func print(_ event: BuildEvent) {
        let line: String
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            line = (try? encoder.encode(event)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        } else {
            switch event {
            case .stepStarted(let ref): line = "▸ \(ref.step)"
            case .stepRestored(let ref): line = "↺ \(ref.step)"
            case .stepDone: return
            case .stepSkipped(let ref, let message): line = "⚠ skipped \(ref.name): \(message)"
            case .emitted(let string): line = string
            case .instructions(let text): guard let text else { return }; line = "→ \(text)"
            case .stepProgress(let progress): guard let text = progress?.text else { return }; line = "  \(text)"
            case .substep(let text): line = "  \(text)"
            case .module(let id, let name, _, _): line = "  \(id).\(name)"
            case .lockWaiting(let lock, let holder): line = "⏸ waiting for the \(lock) lock, held by \(holder ?? "something else")"
            case .lockAcquired(let lock, let seconds): line = "▸ got the \(lock) lock after \(Int(seconds))s"
            case .replayed(let inner):
                if case .stepStarted(let ref) = inner { line = "↺ \(ref.step)" } else { return }
            }
        }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

/// The questions a build asks, on a terminal; with none, a step that
/// needs one fails, saying which.
nonisolated enum TerminalQuestions {
    static func ask(_ question: StepQuestion) throws -> StepAnswer {
        guard isatty(STDIN_FILENO) != 0 else {
            throw StepFailure.failed("the build asks something and there's no terminal to ask on: \(question)")
        }
        switch question {
        case .confirmStepFailure(let name, let message):
            return prompt("\(name) failed (\(message)). Carry on without it? [y/N] ") ? .yes : .no
        case .confirm(let text):
            return prompt("\(text) [y/N] ") ? .yes : .no
        case .choose(let text, let options):
            FileHandle.standardError.write(Data((text + "\n" + options.enumerated().map { "  \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n") + "\n> ").utf8))
            guard let answer = readLine().flatMap(Int.init), (1...options.count).contains(answer) else {
                throw StepFailure.failed("no answer to \(text)")
            }
            return .chose(answer - 1)
        }
    }

    static func prompt(_ text: String) -> Bool {
        FileHandle.standardError.write(Data(text.utf8))
        return readLine()?.lowercased().hasPrefix("y") == true
    }
}
