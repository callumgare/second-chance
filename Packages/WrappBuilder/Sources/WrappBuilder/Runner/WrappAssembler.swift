//
//  WrappAssembler.swift
//  WrappBuilder
//
//  The template laid into the target's tree once its last step is done.

import Foundation

/// What makes a tree an app (decision 2 of the builders plan): the
/// template's files (the launcher and what it brings) laid in after the
/// last step, and its `Info.plist` merged with the tree's. Because it comes
/// last, a new template reaches an app restored entirely from layers, and a
/// tree that came in with an old one (an update's) has it replaced.
public nonisolated enum WrappAssembler {
    /// The keys of `Info.plist` that are the launcher's alone.
    public static let reservedKeys: Set<String> = ["CFBundleExecutable", "SecondChanceLauncherRevision"]

    public struct Problem: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// `template`'s files laid into `tree`. The template's files are
    /// reserved, not its folders: a file a step made in the template's place
    /// is an error naming it, unless it's the same file (the wine module's
    /// in-process helpers, which the template carries too). The tree's
    /// `Info.plist` keys are laid over the template's, but for the
    /// launcher's own (`reservedKeys`).
    public static func layIn(_ template: URL, into tree: URL) throws {
        let files = FileManager.default
        let source = template.appendingPathComponent("Contents")
        let contents = tree.appendingPathComponent("Contents")
        let treePlist = try Plist.read(contents.appendingPathComponent("Info.plist"))
        for key in reservedKeys where treePlist[key] != nil {
            throw Problem(description: "a step set Info.plist's \(key), which is the launcher's")
        }
        for entry in try EngineTree.entries(in: source) {
            let from = source.appendingPathComponent(entry.path), to = contents.appendingPathComponent(entry.path)
            if entry.path == "Info.plist" { continue }
            switch entry.kind {
            case .directory:
                try files.createDirectory(at: to, withIntermediateDirectories: true)
            case .file, .link:
                var info = stat()
                if lstat(to.path, &info) == 0 {
                    guard files.contentsEqual(atPath: from.path, andPath: to.path) else {
                        throw Problem(description: "a step made \(entry.path), which is the launcher's")
                    }
                    try files.removeItem(at: to)
                }
                try files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileCopy.clone(from, to: to)
            }
        }
        var plist = try Plist.read(source.appendingPathComponent("Info.plist"))
        plist.merge(treePlist) { $1 }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }
}
