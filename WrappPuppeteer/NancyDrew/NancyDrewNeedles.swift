//
//  NancyDrewNeedles.swift
//  WrappPuppeteer
//
//  Where the Nancy Drew scenario's reference images are: the nancy-drew
//  module's needles.

import Foundation

/// The nancy-drew module's `needles/` (Modules/nancy-drew, docs/modules.md):
/// the splash screens WrappPuppeteer clicks past and the main menu's quit
/// button.
enum NancyDrewNeedles {
    /// The needles folder: the source tree's when WrappPuppeteer runs from a
    /// build inside it, else the copy of Modules/ in its bundle. The source
    /// tree goes first because a build keeps a reference that was since
    /// deleted or renamed, and doesn't pick up one just made until it is
    /// rebuilt.
    static let root: URL? = {
        let path = "Modules/nancy-drew/needles"
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent(path),
              FileManager.default.fileExists(atPath: bundled.path) else { return nil }
        return bundled
    }()

    /// A folder of needles, if the module has it.
    static func folder(_ name: String) -> URL? {
        root.map { $0.appendingPathComponent(name) }
    }

    /// A needle, if the module has it.
    static func file(_ name: String) -> URL? {
        guard let file = root?.appendingPathComponent(name), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
}
