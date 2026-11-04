//
//  StageTrees.swift
//  WrappBuilder
//
//  Which tree each of a plan's stages is built in.

import Foundation

/// Each stage's tree (decision 2 of the builders plan): a folder laid out
/// as a wrapp, `<stage>.app` in the build's working folder. A stage starts
/// from an empty tree (`FROM scratch`), or from its parent's: carrying on in
/// it when nothing else needs the parent (as a Docker layer stack does),
/// or in a clone of it, made as the stage starts, when another stage is
/// built from the parent too or copies from it. So a linear chain of
/// stages is one tree, and clones are made only where stages branch.
nonisolated struct StageTrees: Sendable {
    /// What each stage starts from, by its place in the plan.
    enum Start: Equatable, Sendable {
        /// An empty tree of its own.
        case empty(URL)
        /// Its parent's tree, which it carries on in.
        case parentsTree(URL)
        /// A clone of its parent's tree, made as it starts.
        case clone(of: URL, into: URL)
    }

    let starts: [Start]

    /// The tree each stage ends in, by name.
    let trees: [String: URL]

    init(plan: BuildPlan, in folder: URL) {
        let stages = plan.stages
        func parent(of stage: PlannedStage) -> Int? {
            let name: String
            switch stage.from {
            case .scratch: return nil
            case .stage(let parent): name = parent
            case .module(let id, _, let moduleStage): name = "\(id.lowercased())/\(moduleStage)"
            }
            return stages.firstIndex { $0.name == name }
        }
        let parents = stages.map(parent(of:))
        // A stage is read again when a second stage is built from it, or a
        // `COPY --from` of it runs in any stage.
        func copiedFrom(_ index: Int) -> Bool {
            stages.flatMap(\.steps).contains { $0.module == nil && $0.instruction == "COPY" && $0.option("from") == stages[index].name }
        }
        func treeName(_ stage: PlannedStage) -> String {
            (stage.name.isEmpty ? "target" : stage.name).replacingOccurrences(of: "/", with: "-") + ".app"
        }
        var starts: [Start] = []
        var trees: [String: URL] = [:]
        var treeOf: [URL] = []
        for (index, stage) in stages.enumerated() {
            let own = folder.appendingPathComponent(treeName(stage))
            if let parent = parents[index] {
                let parentTree = treeOf[parent]
                let children = parents.filter { $0 == parent }.count
                if children == 1, !copiedFrom(parent) {
                    starts.append(.parentsTree(parentTree))
                    treeOf.append(parentTree)
                } else {
                    starts.append(.clone(of: parentTree, into: own))
                    treeOf.append(own)
                }
            } else {
                starts.append(.empty(own))
                treeOf.append(own)
            }
            trees[stage.name] = treeOf[index]
        }
        self.starts = starts
        self.trees = trees
    }

    /// The target's tree: what becomes the wrapp.
    var target: URL? {
        switch starts.last {
        case .empty(let tree)?, .parentsTree(let tree)?: tree
        case .clone(_, let tree)?: tree
        case nil: nil
        }
    }

    /// Make a stage's tree, as it starts.
    static func prepare(_ start: Start) throws {
        let files = FileManager.default
        switch start {
        case .empty(let tree):
            try files.createDirectory(at: tree.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        case .parentsTree:
            break
        case .clone(let parent, let tree):
            if files.fileExists(atPath: tree.path) { try files.removeItem(at: tree) }
            try FileCopy.clone(parent, to: tree)
        }
    }
}
