import Foundation
import Testing
@testable import WrappBuilder
import WrappFormat

/// Stages as trees: one tree down a linear chain, a clone where stages
/// branch, a module's setup planned at its first USE, and the template laid
/// in at the end.
struct StageTreesTests {
    private func stage(_ name: String, from: StageSource, _ steps: [PlannedStep] = []) -> PlannedStage {
        PlannedStage(name: name, from: from, modules: [], steps: steps)
    }

    private let folder = URL(fileURLWithPath: "/builds/x")

    @Test("A linear chain of stages is one tree")
    func aChainIsOneTree() {
        let trees = StageTrees(plan: BuildPlan(edition: "e", stages: [
            stage("wine/prefix", from: .scratch), stage("prefix", from: .module(id: "wine", constraint: "10", stage: "prefix")),
            stage("disc", from: .stage("prefix")),
        ]), in: folder)
        let one = folder.appendingPathComponent("wine-prefix.app")
        #expect(trees.starts == [.empty(one), .parentsTree(one), .parentsTree(one)])
        #expect(trees.target == one)
    }

    @Test("A stage built from by two, or copied from, is cloned for the one after it")
    func branchesAreCloned() {
        let copy = PlannedStep(instruction: "COPY", module: nil, options: ["from": ["files"]], arguments: ["a", "/b"], name: nil, origin: "W:1")
        let trees = StageTrees(plan: BuildPlan(edition: "e", stages: [
            stage("files", from: .scratch), stage("scummvm", from: .scratch), stage("her", from: .stage("scummvm"), [copy]),
            stage("other", from: .stage("files")),
        ]), in: folder)
        #expect(trees.starts[2] == .parentsTree(folder.appendingPathComponent("scummvm.app")))
        // files is copied from, so the stage built from it has a clone.
        #expect(trees.starts[3] == .clone(of: folder.appendingPathComponent("files.app"), into: folder.appendingPathComponent("other.app")))
        #expect(trees.trees["files"] == folder.appendingPathComponent("files.app"))
    }

    @Test("USE plans a module's setup once per tree: its engine, then its setup steps, dependencies first")
    func useSetsAModuleUp() throws {
        let modules = try shippedModules()
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: modules)
        let bundle = try loader.load(bundlesRoot.appendingPathComponent("freeware/skifree")).get()
        let wrappfile = try WrappfileParser.parse(String(contentsOf: bundle.folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
        let plan = try #require(try BuildPlanner(bundle: bundle, wrappfile: wrappfile, modules: modules)
            .plan(edition: "download", conditions: BuildConditions(arch: "arm64", macos: 15)))
        let prefix = try #require(plan.stages.first)
        let setup = prefix.steps.filter(\.setup).map(\.keyword)
        #expect(setup == ["ENGINE", "WINE.HELPERS", "WINE.PREFIX"])
        #expect(prefix.steps.filter(\.setup).first?.arguments.first?.hasPrefix("wine@11.21") == true)
        // The bundle's stage, built from it, sets nothing up again.
        #expect(plan.target?.steps.contains(where: \.setup) == false)
        #expect(plan.bundleSteps.allSatisfy { !$0.setup })
    }

    @Test("Royal Tower's disc edition is a ScummVM tree with no Wine or prefix, the template laid in at the end")
    func royalTowersDiscHasNoWine() async throws {
        let modules = try shippedModules()
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: modules)
        let bundle = try loader.load(bundlesRoot.appendingPathComponent("nancy-drew/royal-tower")).get()
        let wrappfile = try WrappfileParser.parse(String(contentsOf: bundle.folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
        let plan = try #require(try BuildPlanner(bundle: bundle, wrappfile: wrappfile, modules: modules)
            .plan(edition: "cd", conditions: BuildConditions(arch: "arm64", macos: 15)))
        #expect(plan.stages.map(\.name) == ["scummvm", "disc"])

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trees-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        // A stand-in ScummVM, and a disc.
        let engineTree = scratch.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engineTree.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try Data("scummvm".utf8).write(to: engineTree.appendingPathComponent("MacOS/scummvm"))
        try EngineTree.writeList(module: "scummvm", in: engineTree)
        let disc = scratch.appendingPathComponent("disc")
        try FileManager.default.createDirectory(at: disc, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: disc.appendingPathComponent("Game.cif"))

        let configuration = RunnerConfiguration(
            executors: ["scummvm": KeepsData()],
            inputs: GivenInputs(["disc-1": disc]), emitter: PlanRunnerTests.Recorder(),
            fetch: { _, _, _ in throw StepFailure.failed("no downloads") },
            engine: { module, version in EngineStore.Engine(module: module, version: version, hash: "fake", tree: engineTree, prepared: false) })
        var withFiles = plan
        withFiles.files = plan.files
        let target = try await PlanRunner(plan: withFiles, configuration: configuration).build(in: scratch.appendingPathComponent("build"))
        let layout = WrappLayout(app: target)
        #expect(FileManager.default.fileExists(atPath: layout.scummvm.path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/SharedSupport/game/Game.cif").path))
        #expect(!FileManager.default.fileExists(atPath: layout.prefix.path))
        #expect(!FileManager.default.fileExists(atPath: layout.wine.path))
        #expect(try Plist.read(layout.infoPlist)["CFBundleIconFile"] as? String == "nancy-drew.icns")
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/Resources/kept-nancy.dat").path),
                "SCUMMVM.KEEP-DATA nancy.dat didn't reach the scummvm module's executor")

        // The template laid in: its files, and its Info.plist under the tree's.
        let template = scratch.appendingPathComponent("WrappTemplate.app")
        try FileManager.default.createDirectory(at: template.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("launcher".utf8).write(to: template.appendingPathComponent("Contents/MacOS/WrappTemplate"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "WrappTemplate", "CFBundleIconFile": "generic"],
                                           format: .xml, options: 0).write(to: template.appendingPathComponent("Contents/Info.plist"))
        try WrappAssembler.layIn(template, into: target)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/MacOS/WrappTemplate").path))
        let merged = try Plist.read(layout.infoPlist)
        #expect(merged["CFBundleExecutable"] as? String == "WrappTemplate")
        #expect(merged["CFBundleIconFile"] as? String == "nancy-drew.icns")

        // A step that made one of the launcher's files is refused.
        try Data("other".utf8).write(to: target.appendingPathComponent("Contents/MacOS/WrappTemplate"))
        #expect(throws: WrappAssembler.Problem.self) { try WrappAssembler.layIn(template, into: target) }
    }
}

/// A stand-in for the scummvm module's executor (`ScummVMExecutor`, a
/// package of its own): leaves a mark for what `KEEP-DATA` was given.
private nonisolated struct KeepsData: ModuleExecutor {
    static let handles = ["KEEP-DATA"]

    func run(_ step: PlannedStep, in context: any StepContext) async throws {
        for name in step.arguments {
            try Data().write(to: context.tree.appendingPathComponent("Contents/Resources/kept-\(name)"))
        }
    }
}
