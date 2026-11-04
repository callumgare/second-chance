//
//  Plist.swift
//  WrappBuilder
//
//  A property list's top level, read, changed and written back.

import Foundation

nonisolated enum Plist {
    /// `file`'s dictionary (empty when there's no file), changed by `change`
    /// and written back as XML.
    static func update(_ file: URL, _ change: (inout [String: Any]) throws -> Void) throws {
        var plist = try read(file)
        try change(&plist)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file)
    }

    static func read(_ file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw StepFailure.failed("\(file.lastPathComponent) isn't a property list of keys")
        }
        return plist
    }
}
